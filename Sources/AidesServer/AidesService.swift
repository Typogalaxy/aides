import AidesCore
import AidesExecution
import Darwin
import Foundation
import Vapor

struct AidesService: Sendable {
    let host: Host
    let store: StateStore<ServerState>
    let jobs: JobRunner
    let commands: ToolkitCommandJobs

    init(host: Host) async throws {
        self.host = host
        let store = try StateStore(directory: host.directory, defaultState: ServerState())
        self.store = store
        jobs = JobRunner(host: host, store: store)
        commands = ToolkitCommandJobs(store: store)
        let snapshot = await store.snapshot()
        let recoveringTasks = snapshot.app.tasks.contains { work in
            work.status == .running || (work.kind == .retiredMail && !work.status.isTerminal)
        }
        let recoveringFileJobs = snapshot.deviceFiles?.jobs.contains { $0.status == .running } == true
        let recoveringCommands = snapshot.toolkitCommandRuns?.values.contains { $0.status.isActive } == true
        if recoveringTasks || recoveringFileJobs || recoveringCommands {
            try await store.update { state in
                state.deviceFiles?.interruptClaims(at: .now)
                state.deviceFiles?.trimHistory()
                if var runs = state.toolkitCommandRuns {
                    for id in runs.keys where runs[id]?.status.isActive == true {
                        runs[id]?.status = .interrupted
                        runs[id]?.message = "Server restarted. Check the project before running this command again."
                    }
                    state.toolkitCommandRuns = runs
                }
                for index in state.app.tasks.indices {
                    let work = state.app.tasks[index]
                    if work.kind == .retiredMail && !work.status.isTerminal {
                        state.app.tasks[index].status = .cancelled
                        state.app.tasks[index].updatedAt = .now
                        state.app.tasks[index].error = "Local mail transport was removed. Check any prior delivery receipts before sending again."
                    } else if work.status == .running {
                        state.app.tasks[index].status = .waiting
                        state.app.tasks[index].error = "The server stopped during this attempt. Review its outcome before resuming."
                    }
                }
                state.revise()
            }
        }
    }

    func start() async { await jobs.start() }

    func authenticatedDevice(_ request: Request) async throws -> UUID {
        guard let token = request.headers.bearerAuthorization?.token, token.utf8.count == 64,
              let id = await store.snapshot().tokenOwners[Host.digest(token)] else {
            throw Abort(.unauthorized, reason: "Pair this device to continue.")
        }
        return id
    }

    func pair(code: String, name: String) async throws -> PairingResult {
        let name = try Self.required(name, max: 80)
        guard try host.consumeInvite(code) else { throw Abort(.forbidden, reason: "Invalid or expired pairing code.") }
        let token = Host.token()
        let device = PairedDevice(name: name)
        try await store.update { state in
            state.tokenOwners[Host.digest(token)] = device.id
            state.app.devices.append(device)
            state.revise()
        }
        return PairingResult(token: token, deviceID: device.id)
    }

    func revoke(_ id: UUID) async throws -> AppState {
        try await change { state in
            state.app.devices.removeAll { $0.id == id }
            state.tokenOwners = state.tokenOwners.filter { $0.value != id }
            Self.revokeDeviceFileAccess(deviceID: id, in: &state)
        }
    }

    func state(after revision: Int? = nil, deviceID: UUID) async throws -> AppState {
        var snapshot = await store.snapshot()
        for _ in 0..<100 {
            guard revision == snapshot.app.revision else { break }
            try await Task.sleep(for: .milliseconds(150))
            snapshot = await store.snapshot()
        }
        guard snapshot.app.devices.contains(where: { $0.id == deviceID }) else { throw Abort(.unauthorized) }
        var app = snapshot.app
        let storageFiles = ["aides.sqlite3", "aides.sqlite3-wal", "aides.sqlite3-shm"]
        app.metrics.storageBytes = storageFiles.reduce(0) { total, name in
            let file = host.directory.appending(path: name)
            return total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS { app.metrics.processMemoryBytes = Int(clamping: info.resident_size) }
        return app
    }

    func createThread(_ input: NewThread) async throws -> AppState {
        let title = try Self.required(input.title, max: 120)
        return try await change { state in
            try Self.requireProject(input.projectID, in: state)
            guard input.role != .secretary else { throw Abort(.badRequest, reason: "There is already one secretary.") }
            state.app.threads.append(Conversation(title: title, role: input.role, projectID: input.projectID))
        }
    }

    func archive(id: UUID, report: String) async throws -> AppState {
        let report = try Self.required(report, max: 3_000)
        return try await change { state in
            guard let index = state.app.threads.firstIndex(where: { $0.id == id }), state.app.threads[index].role != .secretary else {
                throw Abort(.notFound)
            }
            guard !state.app.tasks.contains(where: { $0.threadID == id && !$0.status.isTerminal }),
                  !state.app.schedules.contains(where: { $0.threadID == id && !$0.paused && $0.nextRun != nil }) else {
                throw Abort(.conflict, reason: "Finish or cancel the conversation’s work before archiving.")
            }
            state.app.threads[index].archivedAt = .now
            state.app.threads[index].report = report
        }
    }

    func message(in id: UUID, input: NewMessage, deviceID: UUID) async throws -> AppState {
        let text = try Self.required(input.text, max: 20_000)
        return try await change { state in
            guard let index = state.app.threads.firstIndex(where: { $0.id == id }), state.app.threads[index].archivedAt == nil else {
                throw Abort(.notFound)
            }
            let toolkitGrant = try Self.makeToolkitGrant(input.toolkitResourceID, deviceID: deviceID, in: state)
            let message = Message(text, role: .user)
            state.app.threads[index].messages.append(message)
            guard let modelID = state.app.settings.defaultModelID else {
                state.app.threads[index].messages.append(Message("Configure a local model in Settings before asking for a reply.", role: .system))
                return
            }
            var task = WorkItem(
                title: "Reply to \(state.app.threads[index].title)", instruction: text,
                threadID: id, projectID: state.app.threads[index].projectID, modelID: modelID, kind: .conversation
            )
            task.toolkitGrant = toolkitGrant
            state.app.tasks.append(task)
            state.replyMessages[task.id] = message.id
        }
    }

    func createProject(_ input: NewProject) async throws -> AppState {
        let name = try Self.required(input.name, max: 120)
        let projectID = UUID()
        let directory: URL
        if let path = input.directory, !path.isEmpty {
            guard path.hasPrefix("/") else { throw Abort(.badRequest, reason: "Use an absolute path on the server.") }
            directory = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            let privateData = host.directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard directory.path != "/", directory.path != privateData,
                  !privateData.hasPrefix(directory.path + "/"), !directory.path.hasPrefix(privateData + "/") else {
                throw Abort(.badRequest, reason: "Choose a working directory separate from Aides data.")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw Abort(.badRequest, reason: "The server cannot find that directory.")
            }
        } else {
            directory = host.directory.appending(path: "Projects/\(projectID.uuidString)", directoryHint: .isDirectory)
        }
        let createsDirectory = input.directory?.isEmpty != false
        if createsDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        do {
            return try await change { state in
                let project = Project(name: name, directory: directory.path)
                state.app.projects.append(project)
                state.app.threads.append(Conversation(title: name, role: .project, projectID: project.id))
            }
        } catch {
            if createsDirectory { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }

    func watchProject(_ id: UUID, enabled: Bool) async throws -> AppState {
        try await change { state in
            guard let index = state.app.projects.firstIndex(where: { $0.id == id }) else { throw Abort(.notFound) }
            state.app.projects[index].watching = enabled
            if !enabled { state.watchedProjects?.removeValue(forKey: id) }
        }
    }

    func addModel(_ input: NewModel) async throws -> AppState {
        let name = try Self.required(input.name, max: 80)
        let model = try Self.required(input.model, max: 200)
        let apiKey = input.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = switch input.kind {
        case .ollama: input.endpoint.isEmpty ? "http://127.0.0.1:11434" : input.endpoint
        case .openAI: input.endpoint.isEmpty ? "https://api.openai.com/v1" : input.endpoint
        case .claude: input.endpoint.isEmpty ? "https://api.anthropic.com/v1" : input.endpoint
        default: input.endpoint
        }
        switch input.kind {
        case .ollama, .openAI, .claude:
            guard let address = URL(string: endpoint), address.user == nil, address.password == nil,
                  address.query == nil, address.fragment == nil, let domain = address.host?.lowercased() else {
                throw Abort(.badRequest, reason: "Invalid model endpoint.")
            }
            let allowed = switch input.kind {
            case .ollama: ["http", "https"].contains(address.scheme ?? "") && ["127.0.0.1", "::1", "[::1]", "localhost"].contains(domain)
            case .openAI: address.scheme == "https" && domain == "api.openai.com"
            default: address.scheme == "https" && domain == "api.anthropic.com"
            }
            guard allowed else { throw Abort(.badRequest, reason: "The endpoint is outside this provider’s allowed addresses.") }
        case .codex, .claudeCode:
            do { _ = try host.executable(for: input.kind) } catch {
                throw Abort(.badRequest, reason: error.localizedDescription)
            }
        case .mock: break
        }
        if input.kind.needsAPIKey {
            guard let apiKey, !apiKey.isEmpty, apiKey.utf8.count <= 1_024,
                  !apiKey.contains(where: { $0.isNewline }) else {
                throw Abort(.badRequest, reason: "Enter the provider’s API key.")
            }
        }
        let profile = ModelProfile(name: name, kind: input.kind, endpoint: endpoint, model: model, hasCredential: input.kind.needsAPIKey)
        if profile.hasCredential, let apiKey {
            try host.saveAPIKey(apiKey, for: profile.id)
        }
        return try await change { state in
            state.app.models.append(profile)
            if input.kind.isLocal && state.app.settings.defaultModelID == nil {
                state.app.settings.defaultModelID = profile.id
            }
        }
    }

    func updateSettings(_ input: SettingsChange) async throws -> AppState {
        let preference = try input.preference.map { try Self.optional($0, max: 2_000) }
        return try await change { state in
            if let id = input.defaultModelID {
                guard state.app.models.contains(where: { $0.id == id && $0.kind.isLocal }) else {
                    throw Abort(.badRequest, reason: "The secretary’s default model must be local.")
                }
                state.app.settings.defaultModelID = id
            }
            if let review = input.reviewModelID {
                guard state.app.models.contains(where: { $0.id == review && $0.kind == .ollama }) else {
                    throw Abort(.badRequest, reason: "The review model must use local Ollama inference.")
                }
                state.app.settings.reviewModelID = review
            } else if input.clearReviewModel == true {
                state.app.settings.reviewModelID = nil
            }
            if let preference, preference != state.app.settings.preference {
                state.app.settings.preference = preference
                state.app.settings.preferenceRevision += 1
            }
        }
    }

    func memories() async -> [MemoryRecord] { await store.snapshot().memory }

    func saveMemory(_ input: NewMemory) async throws -> [MemoryRecord] {
        let key = try Self.required(input.key, max: 100)
        let value = try Self.required(input.value, max: 6_000)
        let scope = input.scope.lowercased()
        return try await store.update { state in
            let scopes = state.app.projects.map { "project:\($0.id.uuidString.lowercased())" } +
                state.app.threads.filter { $0.role == .area }.map { "area:\($0.id.uuidString.lowercased())" }
            guard scope == "global" || scopes.contains(scope) else { throw Abort(.badRequest, reason: "Unknown memory scope.") }
            let source: String
            if let id = input.sourceMessageID {
                guard state.app.threads.contains(where: { thread in
                    thread.messages.contains(where: { $0.id == id && $0.role == .user })
                }) else { throw Abort(.notFound, reason: "The original user message is unavailable.") }
                source = "User message \(id.uuidString)"
            } else {
                source = "User entry"
            }
            if let index = state.memory.firstIndex(where: { $0.scope == scope && $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                state.memory[index].value = value
                state.memory[index].sensitivity = input.sensitivity
                state.memory[index].source = source
                state.memory[index].updatedAt = .now
            } else {
                state.memory.append(MemoryRecord(key: key, value: value, scope: scope, source: source, sensitivity: input.sensitivity))
            }
            state.revise()
            return state.memory
        }
    }

    func deleteMemory(_ id: UUID) async throws -> [MemoryRecord] {
        try await store.update { state in
            state.memory.removeAll { $0.id == id }
            state.revise()
            return state.memory
        }
    }

    func change(_ body: @Sendable (inout ServerState) throws -> Void) async throws -> AppState {
        try await store.update { state in
            try body(&state)
            state.revise()
            return state.app
        }
    }

    static func requireProject(_ id: UUID?, in state: ServerState) throws {
        if let id, !state.app.projects.contains(where: { $0.id == id }) { throw Abort(.notFound, reason: "Project not found.") }
    }

    static func optional(_ value: String, max: Int) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= max * 4, value.count <= max else { throw Abort(.badRequest, reason: "Text is too long.") }
        return value
    }

    static func required(_ value: String, max: Int) throws -> String {
        let value = try optional(value, max: max)
        guard !value.isEmpty else { throw Abort(.badRequest, reason: "Enter a value.") }
        return value
    }
}
