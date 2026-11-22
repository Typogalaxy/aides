import AidesCore
import Foundation
import Observation

struct DeviceFileManifest: Decodable, Sendable {
    var grants: [DeviceFileGrant] = []
    var jobs: [DeviceFileJob] = []
}

struct DeviceFileGrant: Decodable, Identifiable, Sendable {
    let id: UUID
    let deviceID: UUID
    let name: String
    let allowMoves: Bool
    let createdAt: Date
}

struct DeviceFileJob: Decodable, Identifiable, Sendable {
    let id: UUID
    let grantID: UUID
    let deviceID: UUID
    let grantName: String
    let operation: FileOperation
    let path: String
    let destination: String?
    let status: String
    let result: String?
    let error: String?
    let updatedAt: Date
}

enum FileOperation: String, Codable, CaseIterable, Identifiable, Sendable {
    case list, read, move

    var id: Self { self }

    var tool: ToolkitTool {
        switch self {
        case .list: .listDirectory
        case .read: .readTextFile
        case .move: .moveFile
        }
    }

    var title: String { tool.descriptor.title }
}

private struct NewGrant: Encodable, Sendable {
    let name: String
    let allowMoves: Bool
}

struct FileJobRequest: Encodable, Equatable, Sendable {
    let grantID: UUID
    let operation: FileOperation
    let path: String
    let destination: String?
}

private struct OldestFileJob: Decodable, Sendable {
    let job: DeviceFileJob?
}

private struct ClaimRequest: Encodable, Sendable {}

private struct FileJobOutcome: Encodable, Sendable {
    var result: String? = nil
    var error: String? = nil
}

@MainActor
@Observable
final class DeviceFileRelay {
    private(set) var manifest = DeviceFileManifest()
    private(set) var pendingMove: DeviceFileJob?
    private(set) var isWorking = false
    var error: String?

    @ObservationIgnored private var client: ServerClient?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var pendingOutcome: (id: UUID, outcome: FileJobOutcome)?
    @ObservationIgnored private var generation = UUID()

    func start(_ client: ServerClient) {
        stop()
        self.client = client
        let runID = generation
        runTask = Task { [weak self] in
            var delay = Duration.zero
            while !Task.isCancelled {
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let self, self.generation == runID else { return }
                delay = await self.tick(using: client, runID: runID)
            }
        }
    }

    func stop() {
        generation = UUID()
        runTask?.cancel()
        runTask = nil
        client = nil
        isWorking = false
        error = nil
        pendingMove = nil
        pendingOutcome = nil
        manifest = DeviceFileManifest()
    }

    func refresh() async {
        guard let client else { return }
        do {
            try await loadManifest(using: client, runID: generation)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func grantAccess(to folder: URL, displayName: String, allowMoves: Bool) async -> Bool {
        await perform { client, runID in
            let bookmark = try FolderBookmarks.bookmark(for: folder)
            let grant: DeviceFileGrant = try await client.post(
                ["device-files", "grants"], body: NewGrant(name: displayName, allowMoves: allowMoves)
            )
            do {
                try requireConnection(runID)
                try FolderBookmarks.save(bookmark, for: grant.id)
            } catch {
                let _: DeviceFileManifest? = try? await client.delete(["device-files", "grants", grant.id.uuidString])
                throw error
            }
            manifest.grants.append(grant)
        }
    }

    func revoke(_ grant: DeviceFileGrant) async {
        _ = await perform { client, runID in
            let changed: DeviceFileManifest = try await client.delete(["device-files", "grants", grant.id.uuidString])
            if grant.deviceID == client.credential?.deviceID {
                try FolderBookmarks.delete(grant.id)
            }
            try requireConnection(runID)
            manifest = changed
            if pendingMove?.grantID == grant.id { pendingMove = nil }
        }
    }

    func submit(_ request: FileJobRequest, invocationID: UUID) async -> Bool {
        await perform { client, runID in
            do {
                let _: ToolkitCatalog = try await client.get(["toolkit", "catalog"])
            } catch ServerError.response(404, _) {
                // Older servers only accept the device-file request format.
                try requireConnection(runID)
                let job: DeviceFileJob = try await client.post(["device-files", "jobs"], body: request)
                try requireConnection(runID)
                update(job)
                return
            }
            try requireConnection(runID)
            let _: ToolkitInvocation = try await client.post(
                ["toolkit", "invocations"],
                body: ToolkitInvocationRequest(
                    id: invocationID, tool: request.operation.tool, resourceID: request.grantID,
                    path: request.path, destination: request.destination
                )
            )
            try requireConnection(runID)
        }
    }

    func respondToMove(_ jobID: UUID, approved: Bool) async {
        guard let job = pendingMove, job.id == jobID else { return }
        _ = await perform { client, runID in
            if approved {
                try await loadManifest(using: client, runID: runID)
                guard pendingMove?.id == job.id,
                      let grant = manifest.grants.first(where: { $0.id == job.grantID && $0.allowMoves }),
                      grant.deviceID == client.credential?.deviceID,
                      manifest.jobs.first(where: { $0.id == job.id })?.status == "running" else {
                    pendingMove = nil
                    throw RelayError.revoked
                }
                pendingOutcome = (job.id, execute(job))
            } else {
                pendingOutcome = (job.id, FileJobOutcome(error: "The target Mac declined the move."))
            }
            pendingMove = nil
        }
    }

    private func tick(using client: ServerClient, runID: UUID) async -> Duration {
        do {
            if let pendingOutcome {
                let result: DeviceFileJob = try await client.post(
                    ["device-files", "jobs", pendingOutcome.id.uuidString, "finish"], body: pendingOutcome.outcome
                )
                guard generation == runID else { return .seconds(2) }
                self.pendingOutcome = nil
                update(result)
            }
            guard !isWorking else { return .seconds(1) }
            try await loadManifest(using: client, runID: runID)
            guard !isWorking, pendingMove == nil else { return .seconds(2) }
            guard manifest.grants.contains(where: { $0.deviceID == client.credential?.deviceID }) else { return .seconds(3) }
            let response: OldestFileJob = try await client.post(["device-files", "jobs", "next"], body: ClaimRequest())
            guard generation == runID else { return .seconds(2) }
            guard let job = response.job else { return .seconds(2) }
            update(job)
            if job.operation == .move {
                pendingMove = job
            } else {
                pendingOutcome = (job.id, execute(job))
            }
            return .milliseconds(150)
        } catch let failure as ServerError where failure.isUnauthorized {
            guard generation == runID else { return .seconds(2) }
            stop()
            return .seconds(12)
        } catch ServerError.response(let status, _) where [404, 409].contains(status) && pendingOutcome != nil {
            // A restarted server may have marked an unfinished move interrupted. Never replay it.
            guard generation == runID else { return .seconds(2) }
            pendingOutcome = nil
            error = "The server interrupted a file action. Check the source and destination before requesting it again."
            return .seconds(2)
        } catch ServerError.response(404, _) {
            // A server from an earlier desktop build may not implement device-file routes.
            return .seconds(12)
        } catch {
            return .seconds(3)
        }
    }

    private func loadManifest(using client: ServerClient, runID: UUID) async throws {
        let update: DeviceFileManifest = try await client.get(["device-files"])
        try requireConnection(runID)
        manifest = update
        if let pendingMove, !manifest.jobs.contains(where: { $0.id == pendingMove.id && $0.status == "running" }) {
            self.pendingMove = nil
        }
    }

    private func requireConnection(_ runID: UUID) throws {
        guard generation == runID, !Task.isCancelled else { throw CancellationError() }
    }

    private func perform(_ operation: (ServerClient, UUID) async throws -> Void) async -> Bool {
        guard let client, !isWorking else { return false }
        let runID = generation
        isWorking = true
        error = nil
        defer { if generation == runID { isWorking = false } }
        do {
            try await operation(client, runID)
            return true
        } catch is CancellationError {
            return false
        } catch {
            if generation == runID { self.error = error.localizedDescription }
            return false
        }
    }

    private func execute(_ job: DeviceFileJob) -> FileJobOutcome {
        do {
            let folder = try FolderBookmarks.resolve(job.grantID)
            let result: String
            switch job.operation {
            case .list:
                let paths = try ProjectFiles.list(path: job.path.isEmpty ? "." : job.path, in: folder)
                result = paths.isEmpty ? "(Empty directory)" : paths.joined(separator: "\n")
            case .read:
                guard let text = try ProjectFiles.read(path: job.path, in: folder) else { throw RelayError.missingFile }
                result = text
            case .move:
                guard let destination = job.destination else { throw RelayError.missingDestination }
                try ProjectFiles.move(path: job.path, to: destination, in: folder)
                result = "File moved."
            }
            guard result.utf8.count <= 16_384 else { throw RelayError.oversize }
            return FileJobOutcome(result: result)
        } catch {
            return FileJobOutcome(error: error.localizedDescription)
        }
    }

    private func update(_ job: DeviceFileJob) {
        if let index = manifest.jobs.firstIndex(where: { $0.id == job.id }) {
            manifest.jobs[index] = job
        } else {
            manifest.jobs.append(job)
        }
    }
}

private enum FolderBookmarks {
    private static let store = LocalKeychain(service: "org.typogalaxy.aides.folder")

    static func bookmark(for pickedFolder: URL) throws -> Data {
        let folder = pickedFolder.resolvingSymlinksInPath().standardizedFileURL
        try validate(folder)
        return try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func save(_ bookmark: Data, for id: UUID) throws {
        try store.save(bookmark, account: id.uuidString)
    }

    static func delete(_ id: UUID) throws {
        try store.delete(account: id.uuidString)
    }

    static func resolve(_ id: UUID) throws -> URL {
        guard let bookmark = try store.read(account: id.uuidString) else { throw RelayError.missingFolder }
        var stale = false
        let folder = try URL(
            resolvingBookmarkData: bookmark, options: [.withoutUI],
            relativeTo: nil, bookmarkDataIsStale: &stale
        ).standardizedFileURL
        guard !stale else { throw RelayError.missingFolder }
        try validate(folder)
        return folder
    }

    private static func validate(_ folder: URL) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        guard folder.isFileURL, folder.path != "/", folder.path != home, !home.hasPrefix(folder.path + "/"),
              !folder.pathComponents.contains(where: ProjectFiles.isProtectedComponent),
              try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        else { throw RelayError.unsafeFolder }
    }
}

private enum RelayError: LocalizedError {
    case missingFolder, unsafeFolder, missingDestination, missingFile, oversize, revoked

    var errorDescription: String? {
        switch self {
        case .missingFolder: "Share this folder again on the Mac that contains it."
        case .unsafeFolder: "Choose a specific folder outside protected locations."
        case .missingDestination: "A move needs a destination path."
        case .missingFile: "No file was found at that path."
        case .oversize: "The result exceeds 16 KiB. Choose a smaller file or subfolder."
        case .revoked: "The file move is no longer authorized."
        }
    }
}
