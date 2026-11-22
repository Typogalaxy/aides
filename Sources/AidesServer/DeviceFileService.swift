import Foundation
import Vapor

struct DeviceFileGrant: Codable, Identifiable, Sendable {
    let id: UUID
    let deviceID: UUID
    let name: String
    let allowMoves: Bool
    let createdAt: Date

    init(deviceID: UUID, name: String, allowMoves: Bool) {
        id = UUID()
        createdAt = .now
        self.deviceID = deviceID
        self.name = name
        self.allowMoves = allowMoves
    }
}

enum DeviceFileOperation: String, Codable, Sendable {
    case list, read, move
}

enum DeviceFileStatus: String, Codable, Sendable {
    case queued, running, completed, failed, cancelled, interrupted

    var isActive: Bool { self == .queued || self == .running }
}

struct DeviceFileJob: Codable, Identifiable, Sendable {
    let id: UUID
    let grantID: UUID
    let deviceID: UUID
    let grantName: String
    let operation: DeviceFileOperation
    let path: String
    let destination: String?
    var status: DeviceFileStatus
    var result: String?
    var error: String?
    let createdAt: Date
    var updatedAt: Date

    init(grant: DeviceFileGrant, operation: DeviceFileOperation, path: String, destination: String?, now: Date) {
        id = UUID()
        grantID = grant.id
        deviceID = grant.deviceID
        grantName = grant.name
        self.operation = operation
        self.path = path
        self.destination = destination
        status = .queued
        createdAt = now
        updatedAt = now
    }
}

struct DeviceFileState: Codable, Sendable {
    var grants: [DeviceFileGrant] = []
    var jobs: [DeviceFileJob] = []

    mutating func expireClaims(at now: Date) {
        for index in jobs.indices where jobs[index].status == .running && now.timeIntervalSince(jobs[index].updatedAt) >= 120 {
            jobs[index].status = .interrupted
            jobs[index].error = "The device did not report the outcome. Check the target device before trying again."
            jobs[index].updatedAt = now
        }
    }

    mutating func revoke(_ ids: Set<UUID>, at now: Date) {
        grants.removeAll { ids.contains($0.id) }
        for index in jobs.indices where ids.contains(jobs[index].grantID) && jobs[index].status.isActive {
            let running = jobs[index].status == .running
            jobs[index].status = running ? .interrupted : .cancelled
            jobs[index].error = running
                ? "Access was revoked after dispatch. Check the target device before trying again."
                : "Access was revoked before dispatch."
            jobs[index].updatedAt = now
        }
    }

    mutating func trimHistory() {
        let recent = Set(jobs.reversed().lazy.filter { !$0.status.isActive }.prefix(32).map(\.id))
        jobs.removeAll { !$0.status.isActive && !recent.contains($0.id) }
    }
}

struct NewDeviceFileGrant: Decodable, Sendable {
    let name: String
    let allowMoves: Bool?
}

struct NewDeviceFileJob: Decodable, Sendable {
    let grantID: UUID
    let operation: DeviceFileOperation
    let path: String
    let destination: String?
}

struct FinishDeviceFileJob: Decodable, Sendable {
    let result: String?
    let error: String?
}

struct DeviceFileClaim: Encodable, Sendable {
    let job: DeviceFileJob?
}

extension AidesService {
    func deviceFileManifest(deviceID: UUID) async throws -> DeviceFileState {
        let state = await store.snapshot()
        try Self.requireDeviceFileAccess(deviceID, in: state)
        var files = state.deviceFiles ?? DeviceFileState()
        files.expireClaims(at: .now)
        files.trimHistory()
        return files
    }

    func grantDeviceFile(_ input: NewDeviceFileGrant, deviceID: UUID) async throws -> DeviceFileGrant {
        let name = try Self.required(input.name, max: 80)
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Abort(.badRequest, reason: "Enter a folder label without control characters.")
        }
        return try await updateDeviceFiles(for: deviceID) { files, _ in
            let deviceGrantCount = files.grants.lazy.filter { $0.deviceID == deviceID }.count
            guard deviceGrantCount < 16, files.grants.count < 128 else {
                throw Abort(.conflict, reason: "Revoke an existing folder grant before adding another.")
            }
            let grant = DeviceFileGrant(deviceID: deviceID, name: name, allowMoves: input.allowMoves ?? false)
            files.grants.append(grant)
            return grant
        }
    }

    func revokeDeviceFileGrant(_ id: UUID, deviceID: UUID) async throws -> DeviceFileState {
        try await updateDeviceFiles(for: deviceID) { files, now in
            guard files.grants.contains(where: { $0.id == id && $0.deviceID == deviceID }) else {
                throw Abort(.notFound, reason: "Folder grant not found on this device.")
            }
            files.revoke([id], at: now)
            files.trimHistory()
            return files
        }
    }

    func createDeviceFileJob(_ input: NewDeviceFileJob, deviceID: UUID) async throws -> DeviceFileJob {
        let path = input.operation == .list && input.path == "." ? "" : input.path
        do {
            if input.operation != .list || !path.isEmpty { try ProjectFiles.validate(path: path) }
            if input.operation == .move {
                guard let destination = input.destination, destination != path else { throw ProjectFileError.invalidPath }
                try ProjectFiles.validate(path: destination)
            } else if input.destination != nil {
                throw ProjectFileError.invalidPath
            }
        } catch {
            throw Abort(.badRequest, reason: "Use relative paths within the granted folder.")
        }

        return try await updateDeviceFiles(for: deviceID) { files, now in
            guard let grant = files.grants.first(where: { $0.id == input.grantID }) else {
                throw Abort(.notFound, reason: "Folder grant is unavailable.")
            }
            if input.operation == .move && !grant.allowMoves {
                throw Abort(.forbidden, reason: "This folder grant is read-only.")
            }
            guard files.jobs.lazy.filter({ $0.status.isActive }).count < 32 else {
                throw Abort(.conflict, reason: "The device file job queue is full.")
            }
            let job = DeviceFileJob(
                grant: grant, operation: input.operation, path: path, destination: input.destination, now: now
            )
            files.jobs.append(job)
            return job
        }
    }

    func claimDeviceFileJob(deviceID: UUID) async throws -> DeviceFileClaim {
        let state = await store.snapshot()
        try Self.requireDeviceFileAccess(deviceID, in: state)
        guard state.deviceFiles?.jobs.contains(where: { $0.deviceID == deviceID && $0.status == .queued }) == true else {
            return DeviceFileClaim(job: nil)
        }
        return try await updateDeviceFiles(for: deviceID) { files, now in
            guard !files.jobs.contains(where: { $0.deviceID == deviceID && $0.status == .running }),
                  let index = files.jobs.firstIndex(where: { $0.deviceID == deviceID && $0.status == .queued }),
                  files.grants.contains(where: { $0.id == files.jobs[index].grantID && $0.deviceID == deviceID }) else {
                return DeviceFileClaim(job: nil)
            }
            files.jobs[index].status = .running
            files.jobs[index].updatedAt = now
            return DeviceFileClaim(job: files.jobs[index])
        }
    }

    func finishDeviceFileJob(
        _ id: UUID, input: FinishDeviceFileJob, deviceID: UUID
    ) async throws -> DeviceFileJob {
        guard (input.result == nil) != (input.error == nil),
              (input.result?.utf8.count ?? 0) <= 16_384,
              (input.error?.utf8.count ?? 0) <= 512 else {
            throw Abort(.badRequest, reason: "Return either a result of at most 16 KiB or a short error.")
        }
        return try await updateDeviceFiles(for: deviceID) { files, now in
            guard let index = files.jobs.firstIndex(where: { $0.id == id && $0.deviceID == deviceID }) else {
                throw Abort(.notFound, reason: "Device file job not found.")
            }
            let job = files.jobs[index]
            if (job.status == .completed || job.status == .failed),
               job.result == input.result, job.error == input.error { return job }
            guard job.status == .running,
                  files.grants.contains(where: { $0.id == job.grantID && $0.deviceID == deviceID }) else {
                throw Abort(.conflict, reason: "This job is no longer active. Check the target device before retrying.")
            }
            files.jobs[index].status = input.result == nil ? .failed : .completed
            files.jobs[index].result = input.result
            files.jobs[index].error = input.error
            files.jobs[index].updatedAt = now
            return files.jobs[index]
        }
    }

    static func revokeDeviceFileAccess(deviceID: UUID, in state: inout ServerState) {
        guard var files = state.deviceFiles else { return }
        let ids = Set(files.grants.lazy.filter { $0.deviceID == deviceID }.map(\.id))
        files.revoke(ids, at: .now)
        files.trimHistory()
        state.deviceFiles = files
    }

    private static func requireDeviceFileAccess(_ deviceID: UUID, in state: ServerState) throws {
        guard state.app.devices.contains(where: { $0.id == deviceID }) else {
            throw Abort(.unauthorized, reason: "Pair this device to continue.")
        }
    }

    private func updateDeviceFiles<Result: Sendable>(
        for deviceID: UUID, _ operation: @Sendable (inout DeviceFileState, Date) throws -> Result
    ) async throws -> Result {
        try await store.update { state in
            try Self.requireDeviceFileAccess(deviceID, in: state)
            var files = state.deviceFiles ?? DeviceFileState()
            let now = Date.now
            files.expireClaims(at: now)
            let result = try operation(&files, now)
            files.trimHistory()
            state.deviceFiles = files
            return result
        }
    }
}
