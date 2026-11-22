import AidesCore
import AidesExecution
import Foundation
import Vapor

extension AidesService {
    func toolkitMailArchives(deviceID: UUID) async throws -> [ToolkitMailArchive] {
        let state = await store.snapshot()
        try Self.requireMailDevice(deviceID, in: state)
        return (state.toolkitMailArchives ?? [:]).values.sorted {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt > $1.createdAt
        }
    }

    func createToolkitMailArchive(
        _ input: ToolkitMailArchiveRequest, deviceID: UUID
    ) async throws -> ToolkitMailArchive {
        if let existing = try Self.existingArchive(input, deviceID: deviceID, in: await store.snapshot()) {
            return existing
        }
        let access = try mailAccess(id: input.accountID, kind: .archive)
        let preview: ToolkitMailMessage
        do {
            preview = try await ToolkitMailConnector().read(
                account: access.account, token: access.token, messageID: input.messageID, includeBody: false
            )
        } catch {
            throw Self.mailFailure(error)
        }
        return try await store.update { state in
            if let existing = try Self.existingArchive(input, deviceID: deviceID, in: state) { return existing }
            var requests = state.toolkitMailArchives ?? [:]
            let active = requests.values.filter { $0.status.isActive }
            guard active.count < 24 else {
                throw Abort(.conflict, reason: "Review pending mail archives before requesting another.")
            }
            guard !active.contains(where: {
                $0.accountID == input.accountID && $0.messageID == input.messageID
            }) else {
                throw Abort(.conflict, reason: "This message already has a pending archive request.")
            }
            let request = ToolkitMailArchive(
                request: input, account: access.account, message: preview, requestedByDeviceID: deviceID, now: .now
            )
            requests[input.id] = request
            state.toolkitMailArchives = requests
            return request
        }
    }

    func decideToolkitMailArchive(_ id: UUID, approved: Bool, deviceID: UUID) async throws -> ToolkitMailArchive {
        let (archive, access): (ToolkitMailArchive, MailAccountAccess?) = try await store.update { state in
            try Self.requireMailDevice(deviceID, in: state)
            guard var archive = state.toolkitMailArchives?[id] else {
                if state.toolkitMailRetiredArchiveIDs?.contains(id) == true { throw Abort(.gone) }
                throw Abort(.notFound, reason: "Mail archive request not found.")
            }
            guard archive.status == .awaitingConfirmation else { return (archive, nil) }
            let access: MailAccountAccess?
            if approved {
                try Self.requireMailDevice(archive.requestedByDeviceID, in: state)
                let configured = try mailAccess(id: archive.accountID, kind: .archive)
                guard configured.account.provider == archive.accountProvider,
                      configured.account.address == archive.accountAddress else {
                    throw Abort(.conflict, reason: "The selected account changed. Create a new archive request.")
                }
                archive.status = .archiving
                access = configured
            } else {
                archive.status = .declined
                access = nil
            }
            archive.updatedAt = .now
            state.toolkitMailArchives?[id] = archive
            Self.trimToolkitMailArchives(in: &state)
            return (archive, access)
        }
        guard let access else { return archive }

        let status: ToolkitMailArchiveStatus
        let failure: String?
        do {
            try await ToolkitMailConnector().archive(
                account: access.account, token: access.token, messageID: archive.messageID
            )
            status = .archived
            failure = nil
        } catch {
            status = .interrupted
            failure = Self.mailFailure(error).reason
        }
        return try await store.update { state in
            guard var current = state.toolkitMailArchives?[id], current.status == .archiving else {
                throw Abort(.conflict, reason: "The archive record changed. Check the provider before retrying.")
            }
            current.status = status
            current.error = failure
            current.updatedAt = .now
            state.toolkitMailArchives?[id] = current
            Self.trimToolkitMailArchives(in: &state)
            return current
        }
    }

    static func interruptToolkitMailArchives(in state: inout ServerState) {
        let abandoned = state.toolkitMailArchives?.values.filter { $0.status == .archiving } ?? []
        for var archive in abandoned {
            archive.status = .interrupted
            archive.error = "The server stopped before recording the archive result. Check the provider before retrying."
            archive.updatedAt = .now
            state.toolkitMailArchives?[archive.id] = archive
        }
        trimToolkitMailArchives(in: &state)
    }

    private static func existingArchive(
        _ input: ToolkitMailArchiveRequest, deviceID: UUID, in state: ServerState
    ) throws -> ToolkitMailArchive? {
        try requireMailDevice(deviceID, in: state)
        if let existing = state.toolkitMailArchives?[input.id] {
            guard existing.request == input, existing.requestedByDeviceID == deviceID else {
                throw Abort(.conflict, reason: "This archive request ID has already been used.")
            }
            return existing
        }
        guard state.toolkitMailRetiredArchiveIDs?.contains(input.id) != true else {
            throw Abort(.gone, reason: "This archive receipt expired.")
        }
        return nil
    }

    private static func trimToolkitMailArchives(in state: inout ServerState) {
        guard var archives = state.toolkitMailArchives else { return }
        let old = archives.values.filter { !$0.status.isActive }.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.updatedAt > $1.updatedAt
        }.dropFirst(32)
        guard !old.isEmpty else { return }
        var retired = state.toolkitMailRetiredArchiveIDs ?? []
        for archive in old {
            retired.insert(archive.id)
            archives.removeValue(forKey: archive.id)
        }
        state.toolkitMailRetiredArchiveIDs = retired
        state.toolkitMailArchives = archives
    }
}

func registerToolkitMailArchiveRoutes(_ mail: RoutesBuilder, service: AidesService) {
    let archives = mail.grouped("archives")
    archives.get { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.toolkitMailArchives(deviceID: device))
    }
    archives.post { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.createToolkitMailArchive(
            decode(ToolkitMailArchiveRequest.self, request), deviceID: device
        ))
    }
    archives.post(":id", "decision") { request in
        let device = try await service.authenticatedDevice(request)
        guard let parameter = request.parameters.get("id"), let id = UUID(uuidString: parameter) else {
            throw Abort(.badRequest)
        }
        let decision = try decode(ToolkitMailDecision.self, request)
        return try await json(service.decideToolkitMailArchive(id, approved: decision.approved, deviceID: device))
    }
}
