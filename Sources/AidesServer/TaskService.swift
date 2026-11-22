import AidesCore
import Foundation
import Vapor

extension AidesService {
    func createTask(_ input: NewTask) async throws -> AppState {
        let title = try Self.required(input.title, max: 120)
        let instruction = try input.instruction.map { try Self.required($0, max: 20_000) }
        let kind = input.kind ?? .analysis
        guard kind == .analysis || kind == .reminder else {
            throw Abort(.badRequest, reason: "Choose analysis or reminder for a standalone task.")
        }
        return try await change { state in
            let scope = try Self.workScope(thread: input.threadID, project: input.projectID, in: state)
            let profile = try Self.workModel(input.modelID, kind: kind, in: state)
            state.app.tasks.append(Self.makeTask(
                title: title, instruction: instruction, threadID: scope.threadID,
                projectID: scope.projectID, profile: profile, kind: kind, scheduledAt: input.scheduledAt
            ))
        }
    }

    func approveTask(_ id: UUID, approved: Bool) async throws -> AppState {
        try await change { state in
            guard let index = state.app.tasks.firstIndex(where: { $0.id == id }) else { throw Abort(.notFound) }
            guard state.app.tasks[index].status == .waitingApproval else {
                throw Abort(.conflict, reason: "The task is not awaiting cloud approval.")
            }
            let now = Date.now
            state.app.tasks[index].approvedCloud = approved
            state.app.tasks[index].status = if approved {
                state.app.tasks[index].scheduledAt.map { $0 > now } == true ? .scheduled : .queued
            } else {
                .cancelled
            }
            state.app.tasks[index].updatedAt = now
        }
    }

    func cancelTask(_ id: UUID) async throws -> AppState {
        let outcome = try await store.update { state -> (app: AppState, running: [UUID]) in
            guard let task = state.app.tasks.first(where: { $0.id == id }) else { throw Abort(.notFound) }
            if task.status == .cancelled { return (state.app, []) }
            guard !task.status.isTerminal else { throw Abort(.conflict, reason: "The task has already finished.") }

            let ids = Self.branchIDs(root: id, tasks: state.app.tasks)
            let now = Date.now
            let indices = state.app.tasks.indices.filter {
                ids.contains(state.app.tasks[$0].id) && !state.app.tasks[$0].status.isTerminal
            }
            let running = indices.compactMap { index in
                state.app.tasks[index].status == .running ? state.app.tasks[index].id : nil
            }
            for index in indices {
                state.app.tasks[index].status = .cancelled
                state.app.tasks[index].approvedCloud = false
                state.app.tasks[index].updatedAt = now
            }
            state.revise()
            return (state.app, running)
        }
        for runningID in outcome.running {
            await jobs.cancel(runningID)
        }
        return outcome.app
    }

    func resumeTask(_ id: UUID) async throws -> AppState {
        try await change { state in
            guard let index = state.app.tasks.firstIndex(where: { $0.id == id }) else { throw Abort(.notFound) }
            let task = state.app.tasks[index]
            guard task.status == .waiting, task.kind != .review else {
                throw Abort(.conflict, reason: "Only interrupted work can be resumed.")
            }
            if let threadID = task.threadID {
                _ = try Self.workScope(thread: threadID, project: task.projectID, in: state)
            }
            let profile = if let modelID = task.modelID {
                state.app.models.first(where: { $0.id == modelID })
            } else {
                nil as ModelProfile?
            }
            if task.kind != .reminder, profile == nil {
                throw Abort(.conflict, reason: "The original model is unavailable. Create a new task to select another model.")
            }
            let now = Date.now
            state.app.tasks[index].status = if profile?.kind.isLocal == false {
                .waitingApproval
            } else {
                task.scheduledAt.map { $0 > now } == true ? .scheduled : .queued
            }
            state.app.tasks[index].approvedCloud = false
            state.app.tasks[index].error = nil
            state.app.tasks[index].updatedAt = now
        }
    }

    func createSchedule(_ input: NewSchedule) async throws -> AppState {
        let title = try Self.required(input.title, max: 120)
        guard input.kind == .analysis || input.kind == .reminder,
              let timeZone = TimeZone(identifier: input.timeZone),
              input.firstRun.timeIntervalSinceReferenceDate.isFinite else {
            throw Abort(.badRequest, reason: "Choose a valid execution time, time zone and schedule type.")
        }
        return try await change { state in
            let scope = try Self.workScope(thread: input.threadID, project: input.projectID, in: state)
            let profile = try Self.workModel(input.modelID, kind: input.kind, in: state)
            state.app.schedules.append(WorkSchedule(
                title: title, threadID: scope.threadID, projectID: scope.projectID, modelID: profile?.id,
                kind: input.kind, repeatRule: input.repeatRule, timeZone: timeZone, firstRun: input.firstRun
            ))
        }
    }

    func pauseSchedule(_ id: UUID, paused: Bool) async throws -> AppState {
        try await change { state in
            guard let index = state.app.schedules.firstIndex(where: { $0.id == id }) else { throw Abort(.notFound) }
            let schedule = state.app.schedules[index]
            if !paused {
                guard schedule.nextRun != nil else {
                    throw Abort(.conflict, reason: "This schedule has already finished.")
                }
                _ = try Self.workScope(thread: schedule.threadID, project: schedule.projectID, in: state)
            }
            state.app.schedules[index].paused = paused
        }
    }

    static func workScope(
        thread threadID: UUID?, project projectID: UUID?, in state: ServerState
    ) throws -> (threadID: UUID?, projectID: UUID?) {
        try requireProject(projectID, in: state)
        guard let threadID else { return (nil, projectID) }
        guard let thread = state.app.threads.first(where: { $0.id == threadID && $0.archivedAt == nil }) else {
            throw Abort(.notFound, reason: "Active conversation not found.")
        }
        if let threadProject = thread.projectID, let projectID, projectID != threadProject {
            throw Abort(.conflict, reason: "That conversation belongs to a different project.")
        }
        return (threadID, thread.projectID ?? projectID)
    }

    static func workModel(_ id: UUID?, kind: WorkKind, in state: ServerState) throws -> ModelProfile? {
        if kind == .reminder { return nil }
        guard let modelID = id ?? state.app.settings.defaultModelID,
              let model = state.app.models.first(where: { $0.id == modelID }) else {
            throw Abort(.badRequest, reason: "Configure or select a model for the task.")
        }
        return model
    }

    static func makeTask(
        title: String, instruction: String? = nil, threadID: UUID?, projectID: UUID?,
        profile: ModelProfile?, kind: WorkKind, parentID: UUID? = nil,
        scheduleID: UUID? = nil, scheduledAt: Date? = nil, now: Date = .now
    ) -> WorkItem {
        var task = WorkItem(
            title: title, instruction: instruction, threadID: threadID, projectID: projectID,
            modelID: profile?.id, kind: kind, parentID: parentID, scheduleID: scheduleID,
            scheduledAt: scheduledAt, now: now
        )
        if profile?.kind.isLocal == false {
            task.status = .waitingApproval
        }
        return task
    }

    private static func branchIDs(root: UUID, tasks: [WorkItem]) -> Set<UUID> {
        let descendants = Dictionary(grouping: tasks.compactMap { task in
            task.parentID.map { (parent: $0, child: task.id) }
        }, by: \.parent)
        var known: Set<UUID> = []
        var remaining = [root]
        while let id = remaining.popLast(), known.insert(id).inserted {
            remaining.append(contentsOf: (descendants[id] ?? []).map(\.child))
        }
        return known
    }
}
