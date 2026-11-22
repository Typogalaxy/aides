import AidesCore
import AidesExecution
import Foundation

actor JobRunner {
    private let host: Host
    private let store: StateStore<ServerState>
    private let client = ModelClient()
    private var nextWatch = Date.distantPast
    private var running: (id: UUID, handle: Task<Void, Never>)?

    init(host: Host, store: StateStore<ServerState>) {
        self.host = host
        self.store = store
    }

    func start() async {
        defer { running?.handle.cancel() }
        while !Task.isCancelled {
            do {
                try await dispatchSchedules()
                if nextWatch <= .now {
                    nextWatch = Date().addingTimeInterval(20)
                    try await scanWatchedProjects()
                }
                if running == nil, let job = try await claim() {
                    running = (job.id, Task { await run(job) })
                }
                try await Task.sleep(for: .milliseconds(300))
            } catch is CancellationError {
                return
            } catch {
                // Do not print job payloads or provider errors into service logs.
                FileHandle.standardError.write(Data("Task queue could not update local state.\n".utf8))
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func cancel(_ id: UUID) {
        if running?.id == id { running?.handle.cancel() }
    }

    private func claim() async throws -> WorkItem? {
        let snapshot = await store.snapshot()
        guard snapshot.app.tasks.contains(where: Self.isReady) else { return nil }
        return try await store.update { state in
            guard let index = state.app.tasks.firstIndex(where: Self.isReady) else { return nil }
            state.app.tasks[index].status = .running
            state.app.tasks[index].updatedAt = .now
            state.app.tasks[index].error = nil
            state.revise()
            return state.app.tasks[index]
        }
    }

    private static func isReady(_ work: WorkItem) -> Bool {
        work.kind != .review && (work.status == .queued || (work.status == .scheduled && (work.scheduledAt ?? .distantFuture) <= .now))
    }

    private func run(_ work: WorkItem) async {
        defer { running = nil }
        do {
            let output: ModelOutput
            var proposal: CodeProposalResult?
            if work.kind == .reminder {
                output = ModelOutput(text: work.instruction, inputTokens: nil, outputTokens: nil)
            } else {
                let snapshot = await store.snapshot()
                guard let model = snapshot.app.models.first(where: { $0.id == work.modelID }) else {
                    throw StorageError("The pinned model is unavailable.")
                }
                if work.kind == .codeProposal {
                    guard let pending = snapshot.proposals?[work.id] else {
                        throw StorageError("The code proposal snapshot is missing.")
                    }
                    let prompt = try CodeProposal.prompt(for: pending.request)
                    output = try await generate(work, model: model, snapshot: snapshot, codePrompt: prompt)
                    proposal = try CodeProposal.parse(output.text, for: pending.request)
                } else {
                    output = try await generate(work, model: model, snapshot: snapshot)
                }
            }
            if !Task.isCancelled {
                try await finish(work, status: .completed, output: output, proposal: proposal)
            }
        } catch is CancellationError {
            // The submitting service records cancellation. A shutdown is reconciled on restart.
        } catch let error as ModelExecutionError {
            let status: WorkStatus = [.rateLimited, .unavailable, .unauthorized].contains(error) ? .waiting : .failed
            try? await finish(work, status: status, error: error.errorDescription)
        } catch {
            try? await finish(work, status: .waiting, error: (error as? StorageError)?.errorDescription ?? "The task could not complete.")
        }
    }

    private func generate(
        _ work: WorkItem, model: ModelProfile, snapshot: ServerState, codePrompt: String? = nil
    ) async throws -> ModelOutput {
        guard model.kind.isLocal || work.approvedCloud else {
            throw StorageError("Cloud execution requires approval.")
        }
        let input = codePrompt ?? work.instruction
        if !model.kind.isLocal {
            try CloudBoundary.validate(input)
            try await LocalReview.check("Send approved material to \(model.kind.rawValue)", data: input, in: snapshot)
            try Task.checkCancellation()
            let current = await store.snapshot()
            guard current.app.settings.reviewModelID == snapshot.app.settings.reviewModelID,
                  current.app.tasks.contains(where: { $0.id == work.id && $0.approvedCloud && $0.status == .running }) else {
                throw StorageError("The approval or review policy changed before dispatch.")
            }
        }
        if let provider = CodingReviewProvider(rawValue: model.kind.rawValue) {
            return try await CodingReviewClient().generate(.init(
                provider: provider, executable: host.executable(for: model.kind), model: model.model,
                approvedInput: input
            ))
        }
        let provider: ModelProvider = switch model.kind {
        case .mock: .stub
        case .ollama: .ollama
        case .openAI: .openAI
        case .claude: .anthropic
        case .codex, .claudeCode: throw ModelExecutionError.invalidConfiguration
        }
        let endpoint = URL(string: model.endpoint) ?? URL(fileURLWithPath: "/")
        let key = model.kind.needsAPIKey ? try host.apiKey(for: model.id) : nil

        var system = "You are Aides. Be precise, label assumptions, and never claim an action has happened unless you have evidence."
        var messages = [ModelMessage(role: .user, text: input)]
        if model.kind.isLocal, codePrompt == nil, let thread = snapshot.app.threads.first(where: { $0.id == work.threadID }) {
            let context = ContextBuilder.build(
                for: thread, through: snapshot.replyMessages[work.id], question: work.instruction,
                records: snapshot.memory, preference: snapshot.app.settings.preference
            )
            system += "\n" + context.notes
            let history = context.recentMessages.compactMap { message -> ModelMessage? in
                switch message.role {
                case .user: ModelMessage(role: .user, text: message.text)
                case .assistant: ModelMessage(role: .assistant, text: message.text)
                case .system: nil
                }
            }
            messages = work.kind == .conversation && !history.isEmpty ? history : history + messages
        }
        return try await client.generate(.init(
            provider: provider, endpoint: endpoint, model: model.model, apiKey: key,
            system: system, messages: messages, maxOutputTokens: codePrompt == nil ? 2_048 : 16_384
        ))
    }

    private func finish(
        _ work: WorkItem, status: WorkStatus, output: ModelOutput? = nil,
        proposal: CodeProposalResult? = nil, error: String? = nil
    ) async throws {
        try await store.update { state in
            guard let index = state.app.tasks.firstIndex(where: { $0.id == work.id }), state.app.tasks[index].status == .running else {
                return
            }
            state.app.tasks[index].status = status
            state.app.tasks[index].updatedAt = .now
            state.app.tasks[index].result = proposal?.summary ?? output?.text
            if let proposal {
                state.proposals?[work.id]?.result = proposal
            }
            state.app.tasks[index].error = error
            if let output {
                if work.kind != .reminder {
                    state.app.metrics.requests += 1
                    state.app.metrics.inputTokens += output.inputTokens ?? 0
                    state.app.metrics.outputTokens += output.outputTokens ?? 0
                    state.app.metrics.networkBytes += output.networkBytes
                }
                if (work.kind == .conversation || work.kind == .reminder),
                   let i = state.app.threads.firstIndex(where: { $0.id == work.threadID }) {
                    let message = Message(output.text, role: .assistant)
                    let origin = state.replyMessages[work.id]
                    if let j = state.app.threads[i].messages.firstIndex(where: { $0.id == origin }) {
                        state.app.threads[i].messages.insert(message, at: j + 1)
                    } else {
                        state.app.threads[i].messages.append(message)
                    }
                }
            }
            if status.isTerminal { AidesService.reconcileReview(of: work.id, in: &state) }
            state.revise()
        }
    }

    private func scanWatchedProjects() async throws {
        let projects = await store.snapshot().app.projects.filter { $0.watching == true }
        for project in projects {
            guard let directory = project.directory,
                  let observation = await ProjectFileWatcher.snapshot(directory: directory) else { continue }
            let previous = await store.snapshot().watchedProjects?[project.id]
            guard previous != observation else { continue }
            try await store.update { state in
                guard state.app.projects.contains(where: { $0.id == project.id && $0.watching == true }) else { return }
                var baselines = state.watchedProjects ?? [:]
                baselines[project.id] = observation
                state.watchedProjects = baselines
                guard let previous, let index = state.app.threads.firstIndex(where: { $0.role == .secretary }) else { return }
                let delta = ProjectFileWatcher.changes(from: previous, to: observation, limit: 8)
                guard delta.total > 0 else { return }
                let names = (delta.created.map { "Added: " + $0 } +
                             delta.modified.map { "Changed: " + $0 } +
                             delta.removed.map { "Removed: " + $0 }).joined(separator: "\n")
                let notice = "[\(project.name)] \(delta.total) file changes\n\(names)"
                state.app.threads[index].messages.append(Message(notice, role: .system))
                state.revise()
            }
        }
    }

    private func dispatchSchedules() async throws {
        let snapshot = await store.snapshot()
        let now = Date()
        guard snapshot.app.schedules.contains(where: { !$0.paused && ($0.nextRun ?? .distantFuture) <= now }) else { return }
        try await store.update { state in
            for i in state.app.schedules.indices {
                let schedule = state.app.schedules[i]
                guard !schedule.paused, let due = schedule.nextRun, due <= now else { continue }
                state.app.schedules[i].nextRun = schedule.following(now)
                if state.app.tasks.contains(where: { $0.scheduleID == schedule.id && !$0.status.isTerminal }) { continue }
                let taskModel = state.app.models.first(where: { $0.id == schedule.modelID })
                var task = WorkItem(
                    title: schedule.title, threadID: schedule.threadID, projectID: schedule.projectID,
                    modelID: schedule.modelID, kind: schedule.kind, scheduleID: schedule.id, now: now
                )
                if schedule.kind != .reminder && taskModel?.kind.isLocal == false { task.status = .waitingApproval }
                state.app.tasks.append(task)
            }
            state.revise()
        }
    }

}
