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
            var task = Self.makeTask(
                title: title, instruction: instruction, threadID: scope.threadID,
                projectID: scope.projectID, profile: profile, kind: kind, scheduledAt: input.scheduledAt
            )
            let requestedIDs = input.sharedMemoryIDs ?? []
            if !requestedIDs.isEmpty {
                let membership = scope.projectID.map { "project:\($0.uuidString.lowercased())" }
                let area = state.app.threads.first(where: { $0.id == scope.threadID && $0.role == .area })
                    .map { "area:\($0.id.uuidString.lowercased())" }
                guard kind == .analysis, profile?.kind.isLocal == false,
                      requestedIDs.count <= 4, Set(requestedIDs).count == requestedIDs.count else {
                    throw Abort(.badRequest, reason: "Choose up to four authorized memories for a cloud task.")
                }
                let selected = try requestedIDs.map { id in
                    guard let memory = state.memory.first(where: { $0.id == id && $0.sensitivity == .cloudAllowed }),
                          memory.scope == "global" || memory.scope == membership || memory.scope == area else {
                        throw Abort(.forbidden, reason: "A selected memory is outside this task’s sharing scope.")
                    }
                    return memory
                }
                let shared = selected.map { $0.key + ": " + $0.value }.joined(separator: "\n")
                do { try CloudBoundary.validate(shared) } catch {
                    throw Abort(.badRequest, reason: error.localizedDescription)
                }
                task.sharedMemories = selected
            }
            state.app.tasks.append(task)
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
            if !approved { Self.reconcileReview(of: id, in: &state) }
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
            for cancelledID in indices.map({ state.app.tasks[$0].id }) {
                Self.reconcileReview(of: cancelledID, in: &state)
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
            if task.kind == .retiredMail {
                throw Abort(.conflict, reason: "The retired mail transport cannot resume this task.")
            }
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

extension AidesService {
    func createReview(_ input: NewReview) async throws -> AppState {
        let title = try Self.required(input.title, max: 120)
        let instruction = try Self.required(input.instruction, max: 10_000)
        guard (2...4).contains(input.modelIDs.count) else {
            throw Abort(.badRequest, reason: "Choose between two and four reviewers.")
        }
        return try await change { state in
            let scope = try Self.workScope(thread: input.threadID, project: input.projectID, in: state)
            let profiles = try input.modelIDs.map { id in
                guard let model = state.app.models.first(where: { $0.id == id }) else {
                    throw Abort(.badRequest, reason: "One of the review models is unavailable.")
                }
                return model
            }
            let now = Date.now
            var parent = WorkItem(
                title: title, instruction: instruction, threadID: scope.threadID,
                projectID: scope.projectID, kind: .review, now: now
            )
            parent.status = .waiting
            state.app.tasks.append(parent)
            for (index, model) in profiles.enumerated() {
                let question = """
                Independently interpret the task below before execution. State the intended deliverable,                 the acceptance criteria, the assumptions you would make and any ambiguity that could                 materially change the result. Describe specific questions for the user when clarification is needed.

                Task: \(instruction)
                """
                state.app.tasks.append(Self.makeTask(
                    title: "Interpretation \(index + 1) · \(model.name)", instruction: question,
                    threadID: scope.threadID, projectID: scope.projectID, profile: model, kind: .analysis,
                    parentID: parent.id, now: now
                ))
            }
        }
    }

    func clarifyReview(_ id: UUID, text: String) async throws -> AppState {
        let clarification = try Self.required(text, max: 3_000)
        return try await change { state in
            let review = try Self.reviewReadyForDecision(id, state: state)
            let parent = state.app.tasks[review.index]
            _ = try Self.workScope(thread: parent.threadID, project: parent.projectID, in: state)
            let completed = review.children.filter { $0.status == .completed && $0.result?.isEmpty == false }
            guard !completed.isEmpty else {
                throw Abort(.conflict, reason: "The first round did not produce an interpretation to clarify.")
            }
            let now = Date.now
            state.app.tasks[review.index].updatedAt = now
            let notes = completed.compactMap { child in
                child.result.map { "\(child.title)\n\($0.prefix(1_500))" }
            }.joined(separator: "\n\n")
            for (index, child) in completed.enumerated() {
                guard let profile = state.app.models.first(where: { $0.id == child.modelID }) else {
                    throw Abort(.conflict, reason: "An original review model is no longer configured.")
                }
                var instruction = """
                Reassess the task in light of the user's clarification. State the resulting deliverable,                 acceptance criteria and any substantive remaining disagreements. Where possible, give a                 concrete way to test a disputed assumption.

                Task: \(parent.instruction)

                User clarification: \(clarification)
                """
                if profile.kind.isLocal {
                    instruction += "\n\nEarlier interpretations (reference material):\n\(notes)"
                }
                state.app.tasks.append(Self.makeTask(
                    title: "Follow-up \(index + 1) · \(profile.name)", instruction: instruction,
                    threadID: parent.threadID, projectID: parent.projectID, profile: profile, kind: .analysis,
                    parentID: child.id, now: now
                ))
            }
        }
    }

    func closeReview(_ id: UUID) async throws -> AppState {
        try await change { state in
            let review = try Self.reviewReadyForDecision(id, state: state)
            state.app.tasks[review.index].status = .completed
            state.app.tasks[review.index].updatedAt = .now
        }
    }

    private static func reviewReadyForDecision(
        _ id: UUID, state: ServerState
    ) throws -> (index: Int, children: [WorkItem]) {
        guard let index = state.app.tasks.firstIndex(where: { $0.id == id && $0.kind == .review }) else {
            throw Abort(.notFound)
        }
        let parent = state.app.tasks[index]
        let children = state.app.tasks.filter { $0.parentID == id }
        let initialIDs = Set(children.map(\.id))
        guard parent.status == .waiting, parent.result?.isEmpty == false, !children.isEmpty,
              children.allSatisfy({ $0.status.isTerminal }),
              !state.app.tasks.contains(where: { $0.parentID.map(initialIDs.contains) == true }) else {
            throw Abort(.conflict, reason: "The review is not awaiting its one clarification or closure.")
        }
        return (index, children)
    }
}

extension AidesService {
    static func reconcileReview(of childID: UUID, in state: inout ServerState) {
        guard let immediateID = state.app.tasks.first(where: { $0.id == childID })?.parentID,
              let immediate = state.app.tasks.first(where: { $0.id == immediateID }) else { return }
        let reviewID = immediate.kind == .review ? immediate.id : immediate.parentID
        guard let index = state.app.tasks.firstIndex(where: { $0.id == reviewID && $0.kind == .review }),
              state.app.tasks[index].status == .waiting else { return }

        let initial = state.app.tasks.filter { $0.parentID == reviewID }
        guard !initial.isEmpty, initial.allSatisfy(\.status.isTerminal) else { return }
        let initialIDs = Set(initial.map(\.id))
        let followups = state.app.tasks.filter { $0.parentID.map(initialIDs.contains) == true }
        guard followups.allSatisfy(\.status.isTerminal) else { return }

        let initialReport = "Independent interpretations\n\n" + Self.reviewReport(initial)
        if followups.isEmpty {
            state.app.tasks[index].result = initialReport
        } else {
            let followupReport = "Follow-up interpretations\n\n" + Self.reviewReport(followups)
            state.app.tasks[index].result = initialReport + "\n\n" + followupReport
            state.app.tasks[index].status = .completed
        }
        state.app.tasks[index].updatedAt = .now
    }

    private static func reviewReport(_ children: [WorkItem]) -> String {
        children.map { worker in
            "\(worker.title) — \(worker.status.rawValue)\n\(worker.result ?? worker.error ?? "No report.")"
        }.joined(separator: "\n\n")
    }
}
