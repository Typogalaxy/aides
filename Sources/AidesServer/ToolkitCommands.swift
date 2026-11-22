import AidesCore
import AidesExecution
import Foundation
import Vapor

struct ToolkitCommandProfile: Decodable, Sendable {
    let id: String
    let label: String
    let projectID: UUID
    let executable: String
    let arguments: [String]
    let timeoutSeconds: Int?

    var summary: ToolkitCommand { ToolkitCommand(id: id, label: label, projectID: projectID) }

    static func configured() throws -> [Self] {
        let raw = try ToolkitHostConfiguration.read("commands.json")
            ?? ProcessInfo.processInfo.environment["AIDES_TOOLKIT_COMMANDS"]
        guard let raw, !raw.isEmpty else { return [] }
        guard raw.utf8.count <= 24_576,
              let values = try? AppJSON.decoder().decode([Self].self, from: Data(raw.utf8)),
              values.count <= 16, Set(values.map(\.id)).count == values.count,
              values.allSatisfy({ $0.isValid }) else {
            throw Abort(.serviceUnavailable, reason: "Check AIDES_TOOLKIT_COMMANDS on the server.")
        }
        return values
    }

    private var isValid: Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return (1...48).contains(id.utf8.count) && id.unicodeScalars.allSatisfy(allowed.contains)
            && (1...80).contains(label.utf8.count) && executable.hasPrefix("/") && !executable.utf8.contains(0)
            && arguments.count <= 24 && arguments.allSatisfy { $0.utf8.count <= 512 && !$0.utf8.contains(0) }
            && (1...120).contains(timeoutSeconds ?? 30)
    }
}

private struct StartToolkitCommand: Decodable, Sendable {
    let id: UUID
    let approved: Bool
}

actor ToolkitCommandJobs {
    private let store: StateStore<ServerState>
    private var running: Task<Void, Never>?

    init(store: StateStore<ServerState>) { self.store = store }

    fileprivate func start(
        _ input: StartToolkitCommand, profile: ToolkitCommandProfile, deviceID: UUID
    ) async throws -> ToolkitCommandRun {
        guard input.approved else { throw Abort(.forbidden, reason: "Confirm before starting this command.") }
        let created = try await store.update { state -> (ToolkitCommandRun, URL?) in
            guard state.app.devices.contains(where: { $0.id == deviceID }) else { throw Abort(.unauthorized) }
            if let prior = state.toolkitCommandRuns?[input.id] {
                guard prior.commandID == profile.id, prior.requestedByDeviceID == deviceID else { throw Abort(.conflict) }
                return (prior, nil)
            }
            guard state.toolkitCommandRuns?.values.contains(where: { $0.status.isActive }) != true else {
                throw Abort(.conflict, reason: "Another Toolkit command is still running.")
            }
            let scope = try AidesService.workScope(thread: nil, project: profile.projectID, in: state)
            guard let path = state.app.projects.first(where: { $0.id == scope.projectID })?.directory,
                  FileManager.default.isExecutableFile(atPath: profile.executable) else {
                throw Abort(.notFound, reason: "The configured project or executable is unavailable.")
            }
            var isDirectory: ObjCBool = false
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            guard directory.resolvingSymlinksInPath().standardizedFileURL.path == path,
                  FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw Abort(.conflict, reason: "The approved project directory has changed.")
            }
            let run = ToolkitCommandRun(id: input.id, commandID: profile.id, requestedByDeviceID: deviceID)
            var runs = state.toolkitCommandRuns ?? [:]
            runs[input.id] = run
            state.toolkitCommandRuns = runs
            return (run, directory)
        }
        if let directory = created.1 {
            running = Task { await execute(created.0.id, profile: profile, directory: directory) }
        }
        return created.0
    }

    func cancel(_ id: UUID, deviceID: UUID) async throws -> ToolkitCommandRun {
        let snapshot = await store.snapshot()
        guard snapshot.app.devices.contains(where: { $0.id == deviceID }) else { throw Abort(.unauthorized) }
        guard let run = snapshot.toolkitCommandRuns?[id] else { throw Abort(.notFound) }
        if run.status == .running { running?.cancel() }
        return run
    }

    private func execute(_ id: UUID, profile: ToolkitCommandProfile, directory: URL) async {
        let status: ToolkitInvocationStatus
        let output: String?
        let exitCode: Int32?
        let message: String?
        do {
            let result = try await ToolkitCommandProcess.run(
                executable: URL(fileURLWithPath: profile.executable),
                arguments: profile.arguments, directory: directory,
                timeout: .seconds(profile.timeoutSeconds ?? 30)
            )
            status = result.status == 0 ? .completed : .failed
            output = result.output
            exitCode = result.status
            message = nil
        } catch is CancellationError {
            status = .interrupted
            output = nil
            exitCode = nil
            message = "Stop requested. Check the project before running the command again."
        } catch {
            status = .interrupted
            output = nil
            exitCode = nil
            message = "Command did not report a bounded outcome. Check the project before retrying."
        }
        do {
            try await store.update { state in
                guard var runs = state.toolkitCommandRuns, var run = runs[id], run.status.isActive else { return }
                run.status = status
                run.output = output
                run.exitCode = exitCode
                run.message = message
                runs[id] = run
                let recent = Set(runs.values.sorted { $0.createdAt > $1.createdAt }.prefix(32).map(\.id))
                for key in runs.keys where !recent.contains(key) { runs[key]?.output = nil }
                state.toolkitCommandRuns = runs
            }
        } catch {
            FileHandle.standardError.write(Data("Toolkit could not record a command receipt.\n".utf8))
        }
    }
}

func registerToolkitCommandRoutes(_ toolkit: RoutesBuilder, service: AidesService) {
    let commands = toolkit.grouped("commands")
    commands.get { request in
        _ = try await service.authenticatedDevice(request)
        return try json(ToolkitCommandProfile.configured().map(\.summary))
    }
    commands.get("runs") { request in
        _ = try await service.authenticatedDevice(request)
        let runs = await service.store.snapshot().toolkitCommandRuns ?? [:]
        return try json(Array(runs.values.sorted { $0.createdAt > $1.createdAt }.prefix(32)))
    }
    commands.post(":command", "run") { request in
        let device = try await service.authenticatedDevice(request)
        guard let profile = try ToolkitCommandProfile.configured().first(where: { $0.id == request.parameters.get("command") }) else {
            throw Abort(.notFound)
        }
        return try await json(service.commands.start(decode(StartToolkitCommand.self, request), profile: profile, deviceID: device))
    }
    commands.post("runs", ":id", "cancel") { request in
        let device = try await service.authenticatedDevice(request)
        guard let value = request.parameters.get("id"), let id = UUID(uuidString: value) else { throw Abort(.badRequest) }
        return try await json(service.commands.cancel(id, deviceID: device))
    }
}
