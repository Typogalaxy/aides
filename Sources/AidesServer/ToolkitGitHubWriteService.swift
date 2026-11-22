import AidesCore
import AidesExecution
import Foundation
import Vapor

extension AidesService {
    func toolkitGitHubWrites(deviceID: UUID) async throws -> [ToolkitGitHubWrite] {
        let state = await store.snapshot()
        try Self.requireGitHubDevice(deviceID, in: state)
        return (state.toolkitGitHubWrites ?? [:]).values.sorted {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt > $1.createdAt
        }
    }

    func createToolkitGitHubWrite(_ input: ToolkitGitHubWriteRequest, deviceID: UUID) async throws -> ToolkitGitHubWrite {
        try Self.validateToolkitGitHubWrite(input)
        return try await store.update { state in
            try Self.requireGitHubDevice(deviceID, in: state)
            if let existing = state.toolkitGitHubWrites?[input.id] {
                guard input == existing.request, deviceID == existing.requestedByDeviceID else {
                    throw Abort(.conflict, reason: "This GitHub write ID has already been used.")
                }
                return existing
            }
            guard state.toolkitGitHubRetiredWriteIDs?.contains(input.id) != true else {
                throw Abort(.gone, reason: "This GitHub write receipt expired.")
            }
            let access = try toolkitGitHubWriteAccess(input)
            var writes = state.toolkitGitHubWrites ?? [:]
            guard writes.values.lazy.filter({ $0.status.isActive }).count < 24 else {
                throw Abort(.conflict, reason: "Review existing GitHub writes before preparing another.")
            }
            let record = ToolkitGitHubWrite(request: input, repository: access.repository, deviceID: deviceID, now: .now)
            writes[input.id] = record
            state.toolkitGitHubWrites = writes
            state.revise()
            return record
        }
    }

    func decideToolkitGitHubWrite(_ id: UUID, approved: Bool, deviceID: UUID) async throws -> ToolkitGitHubWrite {
        typealias Access = (repository: ToolkitGitHubRepository, token: String)
        let (record, access): (ToolkitGitHubWrite, Access?) = try await store.update { state in
            try Self.requireGitHubDevice(deviceID, in: state)
            guard var record = state.toolkitGitHubWrites?[id] else {
                if state.toolkitGitHubRetiredWriteIDs?.contains(id) == true { throw Abort(.gone) }
                throw Abort(.notFound, reason: "GitHub write not found.")
            }
            guard record.status == .awaitingConfirmation else { return (record, nil) }
            let access: Access?
            if approved {
                try Self.requireGitHubDevice(record.requestedByDeviceID, in: state)
                try Self.validateToolkitGitHubWrite(record.request)
                let configured = try toolkitGitHubWriteAccess(record.request)
                guard configured.repository.owner.caseInsensitiveCompare(record.repositoryOwner) == .orderedSame,
                      configured.repository.name.caseInsensitiveCompare(record.repositoryName) == .orderedSame else {
                    throw Abort(.conflict, reason: "The repository changed. Prepare a new write for the intended repository.")
                }
                access = configured
                record.status = .submitting
            } else {
                access = nil
                record.status = .declined
            }
            record.updatedAt = .now
            state.toolkitGitHubWrites?[id] = record
            Self.trimToolkitGitHubWrites(in: &state, keeping: id)
            state.revise()
            return (record, access)
        }
        guard let access else { return record }

        // Once the submission is recorded durably, the provider call is attempted only by this approval.
        let result: ToolkitGitHubWriteResult?
        let failure: String?
        do {
            result = try await ToolkitGitHubWriteConnector().submit(
                record.request, repository: access.repository, token: access.token
            )
            failure = nil
        } catch ToolkitRemoteError.unauthorized {
            result = nil
            failure = "GitHub did not authorize this request. Check the repository and token before preparing another write."
        } catch {
            result = nil
            failure = "GitHub did not confirm the result. Check the repository before preparing another write."
        }
        return try await store.update { state in
            guard var current = state.toolkitGitHubWrites?[id], current.status == .submitting else {
                throw Abort(.conflict, reason: "The receipt changed. Check the GitHub repository.")
            }
            current.status = result == nil ? .interrupted : .submitted
            current.number = result?.number
            current.url = result?.url
            current.error = failure
            current.updatedAt = .now
            state.toolkitGitHubWrites?[id] = current
            Self.trimToolkitGitHubWrites(in: &state, keeping: id)
            state.revise()
            return current
        }
    }

    static func interruptToolkitGitHubWrites(in state: inout ServerState) {
        let pending = state.toolkitGitHubWrites?.values.filter { $0.status == .submitting } ?? []
        for var record in pending {
            record.status = .interrupted
            record.error = "The server stopped before confirming the result. Check the GitHub repository."
            record.updatedAt = .now
            state.toolkitGitHubWrites?[record.id] = record
        }
        trimToolkitGitHubWrites(in: &state)
    }

    private static func validateToolkitGitHubWrite(_ request: ToolkitGitHubWriteRequest) throws {
        guard request.isValid else {
            throw Abort(.badRequest, reason: "Use a short title and, for a pull request, two different branches in the same repository.")
        }
        do {
            try CloudBoundary.validate([request.title, request.body, request.head ?? "", request.base ?? ""].joined(separator: "\n"))
        } catch {
            throw Abort(.badRequest, reason: "Remove the possible credential from this GitHub write.")
        }
    }

    private static func trimToolkitGitHubWrites(in state: inout ServerState, keeping id: UUID? = nil) {
        guard var writes = state.toolkitGitHubWrites else { return }
        let expired = writes.values.filter {
            $0.id != id && !$0.status.isActive
        }.sorted { $0.updatedAt > $1.updatedAt }.dropFirst(id == nil ? 32 : 31)
        guard !expired.isEmpty else { return }
        var retired = state.toolkitGitHubRetiredWriteIDs ?? []
        for record in expired {
            retired.insert(record.id)
            writes.removeValue(forKey: record.id)
        }
        state.toolkitGitHubRetiredWriteIDs = retired
        state.toolkitGitHubWrites = writes
    }
}

func registerToolkitGitHubWriteRoutes(_ group: RoutesBuilder, service: AidesService) {
    let writes = group.grouped("github", "writes")
    writes.get { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.toolkitGitHubWrites(deviceID: device))
    }
    writes.post { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.createToolkitGitHubWrite(decode(ToolkitGitHubWriteRequest.self, request), deviceID: device))
    }
    writes.post(":id", "decision") { request in
        let device = try await service.authenticatedDevice(request)
        guard let raw = request.parameters.get("id"), let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }
        let input = try decode(ToolkitGitHubWriteDecision.self, request)
        return try await json(service.decideToolkitGitHubWrite(id, approved: input.approved, deviceID: device))
    }
}

private struct ToolkitGitHubWriteDecision: Decodable, Sendable {
    let approved: Bool
}
