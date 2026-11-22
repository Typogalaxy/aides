import AidesCore
import AidesExecution
import Foundation
import Vapor

struct ToolkitCommandProfile: Codable, Sendable {
    let id: String
    let label: String
    let projectID: UUID
    let executable: String
    let arguments: [String]
    let timeoutSeconds: Int?

    func summary() throws -> ToolkitCommand {
        let encoder = AppJSON.encoder()
        encoder.outputFormatting = [.sortedKeys]
        let revision = Host.digest(String(decoding: try encoder.encode(self), as: UTF8.self))
        return ToolkitCommand(
            id: id, label: label, projectID: projectID, executable: executable,
            arguments: arguments, timeoutSeconds: timeoutSeconds ?? 30, revision: revision
        )
    }

    static func configured(in directory: URL) throws -> [Self] {
        let raw = try ToolkitHostConfiguration(directory: directory).read("commands.json")
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
            && executable.utf8.count <= 1_024
            && arguments.count <= 24 && arguments.allSatisfy {
                $0.utf8.count <= 512 && !$0.utf8.contains(0) && (try? CloudBoundary.validate($0)) != nil
            }
            && (1...120).contains(timeoutSeconds ?? 30)
    }
}

private struct StartToolkitCommand: Decodable, Sendable {
    let id: UUID
    let approved: Bool
    let revision: String
}

actor ToolkitCommandJobs {
    private let store: StateStore<ServerState>
    private var running: (id: UUID, task: Task<Void, Never>)?

    init(store: StateStore<ServerState>) { self.store = store }

    fileprivate func start(
        _ input: StartToolkitCommand, profile: ToolkitCommandProfile, deviceID: UUID
    ) async throws -> ToolkitCommandRun {
        guard input.approved else { throw Abort(.forbidden, reason: "Confirm before starting this command.") }
        let summary = try profile.summary()
        let created = try await store.update { state -> (ToolkitCommandRun, URL?) in
            guard state.app.devices.contains(where: { $0.id == deviceID }) else { throw Abort(.unauthorized) }
            if let prior = state.toolkitCommandRuns?[input.id] {
                guard prior.commandID == profile.id, prior.requestedByDeviceID == deviceID,
                      prior.revision == input.revision else { throw Abort(.conflict) }
                return (prior, nil)
            }
            guard summary.revision == input.revision else {
                throw Abort(.conflict, reason: "The configured command changed. Refresh and review it again.")
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
                  !directory.pathComponents.contains(where: ProjectFiles.isProtectedComponent),
                  FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw Abort(.conflict, reason: "The approved project directory has changed.")
            }
            let run = ToolkitCommandRun(
                id: input.id, commandID: profile.id, requestedByDeviceID: deviceID, revision: input.revision
            )
            var runs = state.toolkitCommandRuns ?? [:]
            runs[input.id] = run
            state.toolkitCommandRuns = runs
            return (run, directory)
        }
        if let directory = created.1 {
            let id = created.0.id
            running = (id, Task { await execute(id, profile: profile, directory: directory) })
        }
        return created.0
    }

    func cancel(_ id: UUID, deviceID: UUID) async throws -> ToolkitCommandRun {
        let run = try await store.update { state in
            guard state.app.devices.contains(where: { $0.id == deviceID }) else { throw Abort(.unauthorized) }
            guard var run = state.toolkitCommandRuns?[id] else { throw Abort(.notFound) }
            if run.status == .running {
                run.stopRequested = true
                state.toolkitCommandRuns?[id] = run
            }
            return run
        }
        if run.status == .running, running?.id == id { running?.task.cancel() }
        return run
    }

    func shutdown() async {
        guard let task = running?.task else { return }
        task.cancel()
        await task.value
    }

    private func execute(_ id: UUID, profile: ToolkitCommandProfile, directory: URL) async {
        defer { if running?.id == id { running = nil } }
        let status: ToolkitInvocationStatus
        let output: String?
        let exitCode: Int32?
        let message: String?
        do {
            let current = await store.snapshot()
            guard let run = current.toolkitCommandRuns?[id], run.stopRequested != true,
                  current.app.devices.contains(where: { $0.id == run.requestedByDeviceID }) else {
                throw CancellationError()
            }
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
        return try json(ToolkitCommandProfile.configured(in: service.host.directory).map { try $0.summary() })
    }
    commands.get("runs") { request in
        _ = try await service.authenticatedDevice(request)
        let runs = await service.store.snapshot().toolkitCommandRuns ?? [:]
        return try json(Array(runs.values.sorted { $0.createdAt > $1.createdAt }.prefix(32)))
    }
    commands.post(":command", "run") { request in
        let device = try await service.authenticatedDevice(request)
        guard let profile = try ToolkitCommandProfile.configured(in: service.host.directory).first(where: { $0.id == request.parameters.get("command") }) else {
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
