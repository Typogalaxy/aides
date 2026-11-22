import AidesCore
import Foundation
import Vapor

enum ToolkitLocalAction: String, CaseIterable, Codable, Sendable {
    case searchMemory = "memory.search"
    case listProjects = "projects.list"
    case listProjectFiles = "projects.files.list"
    case readProjectFile = "projects.files.read"
    case listSchedules = "schedules.list"
    case listNotifications = "notifications.list"

    var descriptor: ToolkitLocalDescriptor {
        switch self {
        case .searchMemory:
            ToolkitLocalDescriptor(id: self, title: "Search memory")
        case .listProjects:
            ToolkitLocalDescriptor(id: self, title: "List projects")
        case .listProjectFiles:
            ToolkitLocalDescriptor(id: self, title: "List project files", requiresProject: true, acceptsPath: true)
        case .readProjectFile:
            ToolkitLocalDescriptor(
                id: self, title: "Read project file", requiresProject: true, acceptsPath: true, acceptsQuery: false
            )
        case .listSchedules:
            ToolkitLocalDescriptor(id: self, title: "List schedules")
        case .listNotifications:
            ToolkitLocalDescriptor(id: self, title: "List reminder notifications")
        }
    }
}

struct ToolkitLocalDescriptor: Encodable, Sendable {
    let id: ToolkitLocalAction
    let title: String
    var requiresProject = false
    var acceptsPath = false
    var acceptsQuery = true
}

struct ToolkitLocalActions: Encodable, Sendable {
    let actions = ToolkitLocalAction.allCases.map(\.descriptor)
}

struct ToolkitLocalItem: Codable, Sendable {
    let id: String
    let title: String
    var detail: String?
    var source: String?
    var date: Date?
}

struct ToolkitLocalResults: Codable, Sendable {
    let items: [ToolkitLocalItem]
}

struct ToolkitLocalQuery: Codable, Sendable {
    let action: ToolkitLocalAction
    var threadID: UUID?
    var projectID: UUID?
    var query: String?
    var path: String?
    var limit: Int?

    static func workerSelection(_ selection: ToolkitLocalSelection, projectID: UUID?) throws -> Self {
        guard let action = ToolkitLocalAction(rawValue: selection.action) else {
            throw Abort(.badRequest, reason: "Unknown local Toolkit action.")
        }
        let descriptor = action.descriptor
        if descriptor.requiresProject && projectID == nil {
            throw Abort(.forbidden, reason: "Choose a project for this Toolkit action.")
        }
        guard (1...20).contains(selection.limit ?? 10),
              descriptor.acceptsQuery || selection.query == nil,
              descriptor.acceptsPath || selection.path == nil else {
            throw Abort(.badRequest, reason: "These arguments do not match the local tool.")
        }
        _ = try AidesService.optional(selection.query ?? "", max: 120)
        if let path = selection.path, path != "." {
            do { try ProjectFiles.validate(path: path) } catch {
                throw Abort(.badRequest, reason: "Choose a valid project-relative path.")
            }
        }
        return Self(action: action, query: selection.query, path: selection.path, limit: selection.limit)
    }

    static func execute(
        _ input: ToolkitLocalQuery, threadID: UUID?, projectID: UUID?, in state: ServerState,
        allowProjectDirectory: Bool = false
    ) throws -> ToolkitLocalResults {
        // The caller supplies trusted scope. Scope fields in input are for the paired-device API.
        let action = input.action
        let descriptor = action.descriptor
        let limit = input.limit ?? 10
        guard (1...20).contains(limit),
              descriptor.acceptsQuery || input.query == nil,
              descriptor.acceptsPath || input.path == nil else {
            throw Abort(.badRequest, reason: "These arguments do not match the local tool.")
        }
        let query = try AidesService.optional(input.query ?? "", max: 120)
        let scope = try AidesService.workScope(thread: threadID, project: projectID, in: state)
        let project = state.app.projects.first { $0.id == scope.projectID }
        if descriptor.requiresProject, project?.directory == nil {
            throw Abort(.forbidden, reason: "Choose a project with a granted working directory.")
        }

        let items: [ToolkitLocalItem]
        switch action {
        case .searchMemory:
            let projectScope = project.map { "project:\($0.id.uuidString.lowercased())" }
            let areaScope = state.app.threads.first { $0.id == scope.threadID && $0.role == .area }
                .map { "area:\($0.id.uuidString.lowercased())" }
            items = state.memory.lazy.filter {
                ($0.scope == "global" || $0.scope == projectScope || $0.scope == areaScope)
                    && matches(query, $0.key, $0.value)
            }.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit).map {
                ToolkitLocalItem(
                    id: $0.id.uuidString, title: $0.key, detail: excerpt($0.value, maxBytes: 768),
                    source: $0.source, date: $0.updatedAt
                )
            }
        case .listProjects:
            let projects = project.map { [$0] } ?? (allowProjectDirectory ? state.app.projects : [])
            items = projects.lazy.filter { matches(query, $0.name) }
                .sorted { $0.createdAt > $1.createdAt }.prefix(limit)
                .map { ToolkitLocalItem(id: $0.id.uuidString, title: $0.name, date: $0.createdAt) }
        case .listProjectFiles, .readProjectFile:
            guard let directory = project?.directory else {
                throw Abort(.forbidden, reason: "Choose a project with a granted working directory.")
            }
            items = try projectFiles(action, directory: directory, path: input.path, query: query, limit: limit)
        case .listSchedules:
            items = state.app.schedules.lazy.filter {
                inScope($0.threadID, $0.projectID, thread: scope.threadID, project: scope.projectID)
                    && matches(query, $0.title)
            }.sorted { ($0.nextRun ?? .distantFuture) < ($1.nextRun ?? .distantFuture) }.prefix(limit).map {
                ToolkitLocalItem(
                    id: $0.id.uuidString, title: $0.title,
                    detail: $0.paused ? "Paused" : ($0.nextRun == nil ? "Finished" : $0.repeatRule.rawValue),
                    source: $0.timeZone, date: $0.nextRun
                )
            }
        case .listNotifications:
            items = state.app.tasks.lazy.filter {
                $0.kind == .reminder && $0.status == .completed
                    && inScope($0.threadID, $0.projectID, thread: scope.threadID, project: scope.projectID)
                    && matches(query, $0.title, $0.result ?? "")
            }.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit).map {
                ToolkitLocalItem(
                    id: $0.id.uuidString, title: $0.title, detail: $0.result.map { excerpt($0, maxBytes: 512) },
                    source: "Aides reminder", date: $0.updatedAt
                )
            }
        }
        return ToolkitLocalResults(items: items)
    }

    private static func projectFiles(
        _ action: ToolkitLocalAction, directory: String, path: String?, query: String, limit: Int
    ) throws -> [ToolkitLocalItem] {
        let path = path ?? "."
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            if action == .readProjectFile || path != "." { try ProjectFiles.validate(path: path) }
        } catch {
            throw Abort(.badRequest, reason: "Enter an allowed relative project path.")
        }
        do {
            if action == .listProjectFiles {
                let prefix = path == "." ? "" : path + "/"
                return try ProjectFiles.list(path: path, in: root).lazy.filter { matches(query, $0) }.prefix(limit).map {
                    ToolkitLocalItem(id: prefix + $0, title: $0)
                }
            }
            if let value = try ProjectFiles.read(path: path, in: root) {
                return [ToolkitLocalItem(id: path, title: path, detail: excerpt(value, maxBytes: 8_192))]
            }
        } catch {
            throw Abort(.unprocessableEntity, reason: error.localizedDescription)
        }
        throw Abort(.notFound, reason: "This project file is unavailable.")
    }

    private static func inScope(_ itemThread: UUID?, _ itemProject: UUID?, thread: UUID?, project: UUID?) -> Bool {
        if let thread, itemThread == thread { return itemProject == project }
        return itemThread == nil && itemProject == project
    }

    private static func matches(_ query: String, _ candidates: String...) -> Bool {
        query.isEmpty || candidates.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private static func excerpt(_ value: String, maxBytes: Int) -> String {
        guard value.utf8.count > maxBytes else { return value }
        var prefix = value.utf8.prefix(maxBytes - 3)
        while let next = value.utf8.index(prefix.startIndex, offsetBy: prefix.count, limitedBy: value.utf8.endIndex),
              next < value.utf8.endIndex, (value.utf8[next] & 0xC0) == 0x80 {
            prefix = prefix.dropLast()
        }
        return String(decoding: prefix, as: UTF8.self) + "…"
    }
}

extension AidesService {
    func queryToolkitLocal(_ input: ToolkitLocalQuery, deviceID: UUID) async throws -> ToolkitLocalResults {
        let state = await store.snapshot()
        guard state.app.devices.contains(where: { $0.id == deviceID }) else {
            throw Abort(.unauthorized, reason: "Pair this device to continue.")
        }
        return try ToolkitLocalQuery.execute(
            input, threadID: input.threadID, projectID: input.projectID, in: state, allowProjectDirectory: true
        )
    }
}

func registerToolkitLocalRoutes(_ group: RoutesBuilder, service: AidesService) {
    let local = group.grouped("local")
    local.get("actions") { request in
        _ = try await service.authenticatedDevice(request)
        return try json(ToolkitLocalActions())
    }
    local.post("query") { request in
        let deviceID = try await service.authenticatedDevice(request)
        return try await json(service.queryToolkitLocal(decode(ToolkitLocalQuery.self, request), deviceID: deviceID))
    }
}
