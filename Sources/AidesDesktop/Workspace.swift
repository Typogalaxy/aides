import AidesCore
import Foundation
import Observation

@MainActor
@Observable
final class Workspace {
    var state = AppState()
    var memories: [MemoryRecord] = []
    var address = ServerEndpoint.localAddress
    var deviceName = Host.current().localizedName ?? "Mac"
    var inviteCode = ""
    var newInvite: String?
    var error: String?
    var connectionError: String?
    var isWorking = false
    var isConnected = false
    var deviceID: UUID?

    @ObservationIgnored private var client: ServerClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var hasRestored = false

    func restore() async {
        guard !hasRestored else { return }
        hasRestored = true
        address = UserDefaults.standard.string(forKey: "aides.serverAddress") ?? ServerEndpoint.localAddress
        await perform {
            let endpoint = try ServerEndpoint(address)
            guard let credential = try CredentialStore.read(for: endpoint) else { return }
            try await connect(endpoint, credential: credential)
        }
    }

    func pair() async {
        await perform {
            let endpoint = try ServerEndpoint(address)
            try await redeem(inviteCode.trimmingCharacters(in: .whitespacesAndNewlines), endpoint: endpoint)
        }
    }

    func reconnect() async {
        await perform {
            let endpoint = try ServerEndpoint(address)
            guard let credential = try CredentialStore.read(for: endpoint) else {
                throw ServerError.response(status: 401, message: "Pair this Mac first.")
            }
            try await connect(endpoint, credential: credential)
        }
    }

    func startLocalService() async {
        await perform {
            let endpoint = try ServerEndpoint(ServerEndpoint.localAddress)
            _ = try await LocalService.run("start")
            let service = ServerClient(endpoint: endpoint)
            try await waitForLocalService(service)
            if let credential = try CredentialStore.read(for: endpoint) {
                do {
                    try await connect(endpoint, credential: credential)
                    return
                } catch let failure as ServerError where failure.isUnauthorized {
                    try CredentialStore.delete(for: endpoint)
                }
            }
            let code = try await LocalService.run("invite")
            try await redeem(code, endpoint: endpoint)
        }
    }

    private func waitForLocalService(_ client: ServerClient) async throws {
        var lastError: Error?
        for _ in 0..<12 {
            try Task.checkCancellation()
            do {
                let _: HealthResponse = try await client.get(["health"])
                return
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        if let lastError { throw lastError }
    }

    private func redeem(_ code: String, endpoint: ServerEndpoint) async throws {
        let service = ServerClient(endpoint: endpoint)
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential: AccountCredential = try await service.post(
            ["pair"], body: PairRequest(code: code, name: name.isEmpty ? "Mac" : name)
        )
        do {
            try CredentialStore.save(credential, for: endpoint)
        } catch {
            let authenticated = ServerClient(endpoint: endpoint, credential: credential)
            let _: AppState? = try? await authenticated.delete(["devices", credential.deviceID.uuidString])
            throw error
        }
        try await connect(endpoint, credential: credential)
        inviteCode = ""
    }

    private func connect(_ endpoint: ServerEndpoint, credential: AccountCredential) async throws {
        let service = ServerClient(endpoint: endpoint, credential: credential)
        let initial: AppState = try await service.get(["state"])
        eventTask?.cancel()
        state = initial
        memories = []
        client = service
        deviceID = credential.deviceID
        address = endpoint.url.absoluteString
        UserDefaults.standard.set(address, forKey: "aides.serverAddress")
        isConnected = true
        connectionError = nil
        startEvents(using: service)
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        client = nil
        deviceID = nil
        state = AppState()
        memories = []
        newInvite = nil
        isConnected = false
        connectionError = nil
    }

    func forgetConnection() async {
        await perform {
            let endpoint = try ServerEndpoint(address)
            try CredentialStore.delete(for: endpoint)
            disconnect()
        }
    }

    private func startEvents(using service: ServerClient) {
        eventTask = Task { [weak self] in
            var usesEventStream = true
            while !Task.isCancelled {
                guard let revision = self?.state.revision else { return }
                do {
                    let next: AppState
                    if usesEventStream {
                        next = try await service.get(
                            ["events"], query: [URLQueryItem(name: "after", value: String(revision))]
                        )
                    } else {
                        next = try await service.get(["state"])
                    }
                    guard !Task.isCancelled else { return }
                    self?.apply(next)
                    self?.connectionError = nil
                    if next.revision == revision || !usesEventStream {
                        try await Task.sleep(for: .seconds(1))
                    }
                } catch let failure as ServerError where failure.isUnauthorized {
                    guard !Task.isCancelled else { return }
                    self?.disconnect()
                    self?.error = "This device is no longer authorized. Pair it again from your server Mac."
                    return
                } catch ServerError.response(404, _) where usesEventStream {
                    usesEventStream = false
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.connectionError = "Connection interrupted. Reconnecting to the server…"
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func apply(_ newState: AppState) {
        if newState.revision >= state.revision { state = newState }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do { try await operation() }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }

    private func authenticated() throws -> ServerClient {
        guard let client else {
            throw ServerError.response(status: 401, message: "Pair this Mac with an aides server first.")
        }
        return client
    }

    private func update<Body: Encodable & Sendable>(_ route: [String], _ body: Body) async throws {
        let newState: AppState = try await authenticated().post(route, body: body)
        apply(newState)
    }

    func createConversation(_ title: String, role: String, projectID: UUID?) async -> UUID? {
        var created: UUID?
        await perform {
            let known = Set(state.threads.map(\.id))
            try await update(["threads"], ThreadRequest(title: title, role: role, projectID: projectID))
            created = state.threads.last { $0.title == title && $0.role.rawValue == role && !known.contains($0.id) }?.id
        }
        return created
    }

    func send(_ message: String, in conversationID: UUID) async -> Bool {
        var sent = false
        await perform {
            try await update(["threads", conversationID.uuidString, "messages"], MessageRequest(text: message))
            sent = true
        }
        return sent
    }

    func archive(_ id: UUID, report: String) async -> Bool {
        var archived = false
        await perform {
            try await update(["threads", id.uuidString, "archive"], ArchiveRequest(report: report))
            archived = true
        }
        return archived
    }

    func createProject(_ name: String, directory: String?) async -> UUID? {
        var created: UUID?
        await perform {
            let known = Set(state.projects.map(\.id))
            try await update(["projects"], ProjectRequest(name: name, directory: directory))
            created = state.projects.last { $0.name == name && !known.contains($0.id) }?.id
        }
        return created
    }

    func createTask(_ request: TaskRequest) async -> UUID? {
        var created: UUID?
        await perform {
            let known = Set(state.tasks.map(\.id))
            try await update(["tasks"], request)
            created = state.tasks.last { $0.title == request.title && !known.contains($0.id) }?.id
        }
        return created
    }

    func setProjectWatching(_ id: UUID, enabled: Bool) async {
        await perform { try await update(["projects", id.uuidString, "watch"], ProjectWatchRequest(enabled: enabled)) }
    }

    func createReview(_ request: ReviewRequest) async -> UUID? {
        var created: UUID?
        await perform {
            let known = Set(state.tasks.map(\.id))
            try await update(["reviews"], request)
            created = state.tasks.last { $0.kind == .review && $0.title == request.title && !known.contains($0.id) }?.id
        }
        return created
    }

    func clarifyReview(_ id: UUID, clarification: String) async -> Bool {
        var sent = false
        await perform {
            try await update(["reviews", id.uuidString, "clarify"], ReviewClarification(clarification: clarification))
            sent = true
        }
        return sent
    }

    func finishReview(_ id: UUID) async {
        await perform { try await update(["reviews", id.uuidString, "finish"], EmptyRequest()) }
    }

    func createSchedule(_ request: ScheduleRequest) async -> Bool {
        var created = false
        await perform {
            try await update(["schedules"], request)
            created = true
        }
        return created
    }

    func setSchedulePaused(_ id: UUID, paused: Bool) async {
        await perform { try await update(["schedules", id.uuidString, "pause"], PauseRequest(paused: paused)) }
    }

    func resume(_ id: UUID) async {
        await perform { try await update(["tasks", id.uuidString, "resume"], EmptyRequest()) }
    }

    func cancel(_ taskID: UUID) async {
        await perform { try await update(["tasks", taskID.uuidString, "cancel"], EmptyRequest()) }
    }

    func approve(_ taskID: UUID, approved: Bool) async {
        await perform { try await update(["tasks", taskID.uuidString, "approve"], ApprovalRequest(approved: approved)) }
    }

    func saveSettings(modelID: UUID?, preference: String) async {
        await perform { try await update(["settings"], SettingsRequest(defaultModelID: modelID, preference: preference)) }
    }

    func addModel(_ request: ModelRequest) async -> Bool {
        var saved = false
        await perform {
            try await update(["models"], request)
            saved = true
        }
        return saved
    }

    func createInvite() async {
        await perform {
            let result: InviteResponse = try await authenticated().post(["pair", "invites"], body: EmptyRequest())
            newInvite = result.code
        }
    }

    func revokeDevice(_ id: UUID) async {
        await perform {
            let wasCurrent = id == deviceID
            let currentEndpoint = try ServerEndpoint(address)
            let result: AppState = try await authenticated().delete(["devices", id.uuidString])
            if wasCurrent {
                disconnect()
                try CredentialStore.delete(for: currentEndpoint)
            } else {
                apply(result)
            }
        }
    }

    func refreshMemories() async {
        await perform { memories = try await authenticated().get(["memory"]) }
    }

    func saveMemory(_ request: MemoryRequest) async -> Bool {
        var saved = false
        await perform {
            memories = try await authenticated().post(["memory"], body: request)
            saved = true
        }
        return saved
    }

    func deleteMemory(_ id: UUID) async {
        await perform { memories = try await authenticated().delete(["memory", id.uuidString]) }
    }
}

private struct EmptyRequest: Encodable {}
private struct HealthResponse: Decodable & Sendable { let status: String }
private struct PairRequest: Encodable { let code: String; let name: String }
private struct InviteResponse: Decodable & Sendable { let code: String }
private struct ThreadRequest: Encodable { let title: String; let role: String; let projectID: UUID? }
private struct ArchiveRequest: Encodable { let report: String }
private struct MessageRequest: Encodable { let text: String }
private struct ProjectWatchRequest: Encodable { let enabled: Bool }
private struct ProjectRequest: Encodable { let name: String; let directory: String? }
private struct PauseRequest: Encodable { let paused: Bool }
private struct ApprovalRequest: Encodable { let approved: Bool }
private struct SettingsRequest: Encodable { let defaultModelID: UUID?; let preference: String }

struct TaskRequest: Encodable {
    let title: String
    let instruction: String?
    let threadID: UUID?
    let projectID: UUID?
    let modelID: UUID?
    let scheduledAt: Date?
}

struct ReviewRequest: Encodable {
    let title: String
    let instruction: String
    let modelIDs: [UUID]
    let threadID: UUID?
    let projectID: UUID?
}

private struct ReviewClarification: Encodable { let clarification: String }

struct ScheduleRequest: Encodable {
    let title: String
    let threadID: UUID?
    let projectID: UUID?
    let modelID: UUID?
    let kind: String
    let repeatRule: String
    let timeZone: String
    let firstRun: Date
}

struct ModelRequest: Encodable {
    let name: String
    let kind: String
    let endpoint: String
    let model: String
    let apiKey: String?
}

struct MemoryRequest: Encodable {
    let key: String
    let value: String
    let scope: String
    let sensitivity: String
}

enum LocalService {
    static var isBundled: Bool { Bundle.main.url(forResource: "aides-service", withExtension: nil) != nil }

    static func run(_ command: String) async throws -> String {
        guard let executable = Bundle.main.url(forResource: "aides-service", withExtension: nil) else {
            throw ServerError.response(status: 404, message: "Use the packaged aides app to start a local server, or start AidesServer manually.")
        }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = [command]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ServerError.response(
                    status: 500, message: "The background service could not complete “\(command)”."
                )
            }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
