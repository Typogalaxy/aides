import AidesCore
import AidesExecution
import Foundation
import Vapor

struct ComputerStoredRun: Codable, Sendable {
    var run: ComputerRun
    var approvedUntil: Date?
    var claimedAt: Date?
    var lastReceiptID: UUID?

    mutating func transition(_ status: ComputerRunStatus, message: String? = nil, now: Date = .now) {
        run.status = status
        run.updatedAt = now
        run.message = message
        run.pendingAction = nil
        run.pendingReview = nil
        if status != .queued && status != .awaitingApproval {
            run.pendingCommandID = nil
            claimedAt = nil
        }
        if !status.isActive { approvedUntil = nil }
    }
}

struct NewComputerRun: Decodable, Sendable {
    let id: UUID
    let deviceID: UUID
    let appIDs: [String]
    let instruction: String
    let includeImages: Bool
    let modelID: UUID?
    let threadID: UUID?
}

struct ComputerPermission: Decodable, Sendable {
    let approved: Bool
    let allowRoutineActions: Bool?
    let allowBackground: Bool?
}

struct ComputerDecision: Decodable, Sendable {
    let approved: Bool
    let actionID: UUID
}

struct ComputerReceipt: Decodable, Sendable {
    let commandID: UUID
    let observation: ComputerObservation?
    let error: String?
}

actor ComputerRuns {
    private let store: StateStore<ServerState>
    private var commands: [UUID: ComputerCommand] = [:]
    private var reviews: [UUID: ComputerReviewContext] = [:]
    private var recentWindows: [UUID: [ComputerObservation]] = [:]
    private var planning: [UUID: (receiptID: UUID, task: Task<Void, Never>)] = [:]

    init(store: StateStore<ServerState>) {
        self.store = store
    }

    func list(deviceID: UUID) async throws -> [ComputerRun] {
        let state = await store.snapshot()
        try Self.requirePaired(deviceID, in: state)
        return (state.computerRuns ?? [:]).values.map(\.run)
            .filter { Self.canView($0, deviceID: deviceID) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(50).map { run in
                var view = run
                if run.status == .awaitingApproval, run.deviceID == deviceID, let id = run.pendingCommandID {
                    view.pendingAction = commands[id]?.action
                    view.pendingReview = reviews[id]
                }
                return view
            }
    }

    func create(_ input: NewComputerRun, from deviceID: UUID) async throws -> ComputerRun {
        let instruction = try AidesService.required(input.instruction, max: 2_000)
        guard (1...5).contains(input.appIDs.count), Set(input.appIDs).count == input.appIDs.count,
              input.appIDs.allSatisfy(ComputerApp.isEligible) else {
            throw Abort(.badRequest, reason: "Choose up to five eligible apps on the target Mac.")
        }
        return try await store.update { state in
            try Self.requirePaired(deviceID, in: state)
            try Self.requirePaired(input.deviceID, in: state)
            if let existing = state.computerRuns?[input.id]?.run {
                guard existing.requestedByDeviceID == deviceID, existing.deviceID == input.deviceID,
                      existing.appIDs == input.appIDs, existing.instruction == instruction,
                      existing.includeImages == input.includeImages, existing.threadID == input.threadID,
                      input.modelID == nil || existing.modelID == input.modelID else { throw Abort(.conflict) }
                return existing
            }
            let existing = (state.computerRuns ?? [:]).values.map(\.run)
            guard existing.filter({ !$0.status.isTerminal }).count < 24 else {
                throw Abort(.conflict, reason: "Finish or stop existing desktop tasks before adding more.")
            }
            guard let modelID = input.modelID ?? state.app.settings.defaultModelID,
                  state.app.models.contains(where: { $0.id == modelID && $0.kind == .ollama }) else {
                throw Abort(.badRequest, reason: "Select a configured local Ollama model for Computer Use.")
            }
            if let threadID = input.threadID {
                guard state.app.threads.contains(where: { $0.id == threadID && $0.archivedAt == nil }) else {
                    throw Abort(.notFound, reason: "The source conversation is unavailable.")
                }
            }
            let run = ComputerRun(
                id: input.id, deviceID: input.deviceID, requestedByDeviceID: deviceID, appIDs: input.appIDs,
                instruction: instruction, modelID: modelID, includeImages: input.includeImages, threadID: input.threadID
            )
            var runs = state.computerRuns ?? [:]
            runs[input.id] = ComputerStoredRun(run: run)
            state.computerRuns = runs
            return run
        }
    }

    func permit(_ id: UUID, input: ComputerPermission, deviceID: UUID) async throws -> ComputerRun {
        let snapshot = await store.snapshot()
        let run = try Self.find(id, deviceID: deviceID, in: snapshot, targetOnly: true).run
        guard let first = run.appIDs.first else { throw Abort(.conflict) }
        guard !input.approved || input.allowBackground != true || !run.includeImages else {
            throw Abort(.badRequest, reason: "Background Computer Use requires a text-only observation grant.")
        }
        let command = ComputerCommand(
            id: UUID(), runID: id, appIDs: run.appIDs, includeImages: run.includeImages,
            action: ComputerAction(kind: .observe, appID: first), allowBackground: input.allowBackground == true
        )
        if input.approved { commands[command.id] = command }
        do {
            return try await store.update { state in
                var entry = try Self.find(id, deviceID: deviceID, in: state, targetOnly: true)
                guard entry.run.status == .awaitingPermission else { throw Abort(.conflict) }
                if input.approved {
                    try Self.requirePaired(entry.run.requestedByDeviceID, in: state)
                    guard (state.computerRuns ?? [:]).values.allSatisfy({
                        $0.run.id == id || $0.run.deviceID != deviceID || !$0.run.status.isActive
                    }) else {
                        throw Abort(.conflict, reason: "Another Computer Use task is active on this Mac.")
                    }
                    entry.approvedUntil = Date.now.addingTimeInterval(900)
                    entry.run.allowRoutineActions = input.allowRoutineActions == true
                    entry.run.allowBackground = input.allowBackground == true
                    entry.run.pendingCommandID = command.id
                    entry.transition(.queued)
                } else {
                    entry.transition(.stopped, message: "The target Mac declined access.")
                }
                state.computerRuns?[id] = entry
                return entry.run
            }
        } catch {
            clearCommand(command.id)
            throw error
        }
    }

    func next(for deviceID: UUID) async throws -> ComputerClaim {
        let snapshot = await store.snapshot()
        try Self.requirePaired(deviceID, in: snapshot)
        let available = commands
        guard (snapshot.computerRuns ?? [:]).values.contains(where: {
            $0.run.deviceID == deviceID && $0.run.status == .queued
        }) else { return ComputerClaim(command: nil) }
        return try await store.update { state in
            try Self.requirePaired(deviceID, in: state)
            guard let id = (state.computerRuns ?? [:]).values.first(where: {
                $0.run.deviceID == deviceID && $0.run.status == .queued
            })?.run.id, var entry = state.computerRuns?[id] else { return ComputerClaim(command: nil) }
            try Self.requirePaired(entry.run.requestedByDeviceID, in: state)
            guard let deadline = entry.approvedUntil, deadline > .now,
                  let commandID = entry.run.pendingCommandID, let command = available[commandID] else {
                return ComputerClaim(command: nil)
            }
            entry.run.status = .running
            entry.run.updatedAt = .now
            entry.claimedAt = .now
            state.computerRuns?[id] = entry
            return ComputerClaim(command: command)
        }
    }

    func checkClaim(_ id: UUID, commandID: UUID, deviceID: UUID) async throws -> ComputerRun {
        let state = await store.snapshot()
        let entry = try Self.find(id, deviceID: deviceID, in: state, targetOnly: true)
        try Self.requirePaired(entry.run.requestedByDeviceID, in: state)
        guard entry.run.status == .running, entry.run.pendingCommandID == commandID,
              entry.claimedAt != nil, (entry.approvedUntil ?? .distantPast) > .now else { throw Abort(.conflict) }
        return entry.run
    }

    func receipt(_ id: UUID, input: ComputerReceipt, deviceID: UUID) async throws -> ComputerRun {
        guard (input.observation == nil) != (input.error == nil), (input.error?.utf8.count ?? 0) <= 512 else {
            throw Abort(.badRequest, reason: "Send a single observation or error.")
        }
        let command = commands[input.commandID]
        let outcome = try await store.update { state -> (run: ComputerRun, plan: Bool) in
            var entry = try Self.find(id, deviceID: deviceID, in: state, targetOnly: true)
            if entry.lastReceiptID == input.commandID { return (entry.run, false) }
            try Self.requirePaired(entry.run.requestedByDeviceID, in: state)
            guard entry.run.status == .running, entry.run.pendingCommandID == input.commandID,
                  entry.claimedAt != nil, (entry.approvedUntil ?? .distantPast) > .now,
                  let command, command.runID == id else { throw Abort(.conflict, reason: "The action is no longer active.") }
            if let observation = input.observation {
                guard observation.isValid(allowImages: entry.run.includeImages, expectedAppID: command.action.appID),
                      observation.isBackground != true || entry.run.allowBackground == true,
                      observation.screenshot == nil || entry.run.allowBackground != true else {
                    throw Abort(.badRequest, reason: "The observation exceeded its window or data scope.")
                }
                entry.run.steps.append(ComputerStep(
                    number: entry.run.steps.count + 1, kind: command.action.kind, appID: command.action.appID
                ))
                entry.transition(.running)
            } else {
                // This receipt cannot establish whether the action reached the UI.
                entry.transition(.interrupted, message: "The target Mac could not verify the step. Check the window before resuming.")
            }
            entry.lastReceiptID = input.commandID
            state.computerRuns?[id] = entry
            return (entry.run, input.observation != nil)
        }
        clearCommand(input.commandID)
        if outcome.plan, let observation = input.observation {
            var windows = recentWindows[id] ?? []
            windows.removeAll { $0.appID == observation.appID }
            windows.append(ComputerObservation(
                appID: observation.appID, windowTitle: observation.windowTitle, elements: observation.elements,
                isBackground: observation.isBackground
            ))
            recentWindows[id] = Array(windows.suffix(3))
            let receiptID = input.commandID
            planning[id] = (receiptID, Task { await plan(id, observation: observation, receiptID: receiptID) })
        } else if !outcome.run.status.isActive {
            recentWindows.removeValue(forKey: id)
        }
        return outcome.run
    }

    func decide(_ id: UUID, input: ComputerDecision, deviceID: UUID) async throws -> ComputerRun {
        let exists = commands[input.actionID]?.runID == id
        let run = try await store.update { state in
            var entry = try Self.find(id, deviceID: deviceID, in: state, targetOnly: true)
            try Self.requirePaired(entry.run.requestedByDeviceID, in: state)
            guard entry.run.status == .awaitingApproval, entry.run.pendingCommandID == input.actionID,
                  exists, (entry.approvedUntil ?? .distantPast) > .now else {
                throw Abort(.conflict, reason: "The proposal changed or expired.")
            }
            if input.approved {
                entry.transition(.queued)
            } else {
                entry.transition(.paused, message: "The target Mac declined the proposed step.")
            }
            state.computerRuns?[id] = entry
            return entry.run
        }
        if !input.approved {
            clearCommand(input.actionID)
            recentWindows.removeValue(forKey: id)
        }
        return run
    }

    func control(_ id: UUID, verb: String, deviceID: UUID) async throws -> ComputerRun {
        let result = try await store.update { state -> (ComputerRun, UUID?) in
            var entry = try Self.find(id, deviceID: deviceID, in: state)
            guard !entry.run.status.isTerminal else {
                if verb == "stop", entry.run.status == .stopped { return (entry.run, nil) }
                throw Abort(.conflict)
            }
            let pending = entry.run.pendingCommandID
            switch verb {
            case "pause":
                entry.transition(.paused, message: "Paused by the user. Check any action already in progress.")
            case "resume":
                guard entry.run.status == .paused || entry.run.status == .interrupted else { throw Abort(.conflict) }
                try Self.requirePaired(entry.run.deviceID, in: state)
                try Self.requirePaired(entry.run.requestedByDeviceID, in: state)
                guard entry.run.steps.count < Self.stepLimit else {
                    throw Abort(.conflict, reason: "This task exhausted its step budget. Create a new task to continue.")
                }
                entry.transition(.awaitingPermission)
                entry.run.requiresFreshApproval = true
            case "stop":
                entry.transition(.stopped, message: "Stopped by the user. Check any action already in progress.")
            default:
                throw Abort(.badRequest)
            }
            state.computerRuns?[id] = entry
            return (entry.run, pending)
        }
        if let pending = result.1 { clearCommand(pending) }
        if verb != "resume" {
            planning.removeValue(forKey: id)?.task.cancel()
            recentWindows.removeValue(forKey: id)
        }
        return result.0
    }

    private func plan(_ id: UUID, observation: ComputerObservation, receiptID: UUID) async {
        defer {
            if planning[id]?.receiptID == receiptID { planning.removeValue(forKey: id) }
        }
        let snapshot = await store.snapshot()
        guard let entry = snapshot.computerRuns?[id],
              Self.canContinue(entry, receiptID: receiptID, in: snapshot) else {
            if planning[id]?.receiptID == receiptID { recentWindows.removeValue(forKey: id) }
            return
        }
        guard entry.run.steps.count < Self.stepLimit else {
            await pausePlanning(id, receiptID: receiptID, message: "The Computer Use step budget was reached.")
            return
        }
        guard let model = snapshot.app.models.first(where: { $0.id == entry.run.modelID && $0.kind == .ollama }),
              let endpoint = URL(string: model.endpoint) else {
            await pausePlanning(id, receiptID: receiptID, message: "The pinned local model is unavailable.")
            return
        }
        do {
            let action = try await ComputerUseModel().decide(
                endpoint: endpoint, model: model.model, instruction: entry.run.instruction,
                apps: entry.run.appIDs.map { ComputerApp(id: $0, name: $0) },
                observation: observation,
                recent: entry.run.steps.suffix(8).map { "Step \($0.number) completed: \($0.kind.rawValue) in \($0.appID ?? "unknown app")." },
                allowBackground: entry.run.allowBackground == true, priorWindows: recentWindows[id] ?? []
            )
            try Task.checkCancellation()
            guard action.isValid(allowedAppIDs: entry.run.appIDs, observation: observation),
                  entry.run.allowBackground != true || action.supportsBackground,
                  action.x == nil || observation.screenshot != nil else {
                await pausePlanning(id, receiptID: receiptID, message: "The model did not propose a supported action. Review the window.")
                return
            }
            try await publish(action, for: entry.run, observation: observation, receiptID: receiptID)
        } catch is CancellationError {
        } catch {
            await pausePlanning(id, receiptID: receiptID, message: "The local model could not produce the next action. Check its profile.")
        }
    }

    private func publish(
        _ action: ComputerAction, for run: ComputerRun, observation: ComputerObservation, receiptID: UUID
    ) async throws {
        let terminal = action.kind == .finish || action.kind == .handoff
        let command = ComputerCommand(
            id: UUID(), runID: run.id, appIDs: run.appIDs, includeImages: run.includeImages,
            action: action, allowBackground: run.allowBackground == true
        )
        if !terminal {
            commands[command.id] = command
            let element = observation.elements.first(where: { $0.id == action.elementID })
            reviews[command.id] = ComputerReviewContext(windowTitle: observation.windowTitle, label: element?.label, role: element?.role)
        }
        do {
            let retained = try await store.update { state in
                guard var entry = state.computerRuns?[run.id], Self.canContinue(entry, receiptID: receiptID, in: state) else {
                    return false
                }
                switch action.kind {
                case .finish:
                    entry.transition(.completed)
                    entry.run.result = action.text
                    if let threadID = entry.run.threadID, let text = action.text,
                       let index = state.app.threads.firstIndex(where: { $0.id == threadID && $0.archivedAt == nil }) {
                        state.app.threads[index].messages.append(Message("Computer Use: " + text, role: .system))
                        state.revise()
                    }
                case .handoff:
                    entry.transition(.paused, message: "The local model requested that you take over.")
                    entry.run.result = action.text
                default:
                    entry.run.pendingCommandID = command.id
                    if action.needsReview(observation: observation, allowRoutineActions: entry.run.allowRoutineActions == true) {
                        entry.transition(.awaitingApproval)
                    } else {
                        entry.transition(.queued)
                    }
                }
                state.computerRuns?[run.id] = entry
                return true
            }
            if !retained { clearCommand(command.id) }
            if retained && terminal { recentWindows.removeValue(forKey: run.id) }
        } catch {
            clearCommand(command.id)
            throw error
        }
    }

    private func pausePlanning(_ id: UUID, receiptID: UUID, message: String) async {
        do {
            let paused = try await store.update { state in
                guard var entry = state.computerRuns?[id], Self.canContinue(entry, receiptID: receiptID, in: state) else { return false }
                entry.transition(.paused, message: message)
                state.computerRuns?[id] = entry
                return true
            }
            if paused { recentWindows.removeValue(forKey: id) }
        } catch {
            FileHandle.standardError.write(Data("Computer Use could not record a paused task.\n".utf8))
        }
    }

    func start() async {
        while !Task.isCancelled {
            do {
                try await expire()
                try await Task.sleep(for: .seconds(2))
            } catch is CancellationError {
                break
            } catch {
                try? await Task.sleep(for: .seconds(3))
            }
        }
        for job in planning.values { job.task.cancel() }
        planning.removeAll()
        commands.removeAll()
        reviews.removeAll()
        recentWindows.removeAll()
    }

    func reconcileRevocation(of deviceID: UUID) async {
        let state = await store.snapshot()
        let ids = Set((state.computerRuns ?? [:]).values.lazy.filter { Self.canView($0.run, deviceID: deviceID) }.map(\.run.id))
        for id in ids {
            planning.removeValue(forKey: id)?.task.cancel()
            recentWindows.removeValue(forKey: id)
        }
        let discarded = commands.values.filter { ids.contains($0.runID) }.map(\.id)
        for id in discarded { clearCommand(id) }
    }

    private func clearCommand(_ id: UUID) {
        commands.removeValue(forKey: id)
        reviews.removeValue(forKey: id)
    }

    private func expire() async throws {
        let snapshot = await store.snapshot()
        let now = Date.now
        guard (snapshot.computerRuns ?? [:]).values.contains(where: { Self.isExpired($0, at: now) }) else { return }
        let expired = try await store.update { state -> [(runID: UUID, commandID: UUID?)] in
            var finished: [(UUID, UUID?)] = []
            for id in (state.computerRuns ?? [:]).keys {
                guard var entry = state.computerRuns?[id], Self.isExpired(entry, at: now) else { continue }
                finished.append((id, entry.run.pendingCommandID))
                entry.transition(.interrupted, message: "The device or task authorization timed out. Verify the latest UI state.")
                state.computerRuns?[id] = entry
            }
            return finished
        }
        for (id, commandID) in expired {
            if let commandID { clearCommand(commandID) }
            planning.removeValue(forKey: id)?.task.cancel()
            recentWindows.removeValue(forKey: id)
        }
    }

    private static let stepLimit = 40

    private static func isExpired(_ entry: ComputerStoredRun, at now: Date) -> Bool {
        entry.run.status.isActive && (
            (entry.approvedUntil ?? .distantPast) <= now ||
            entry.claimedAt.map { now.timeIntervalSince($0) > 50 } == true ||
            (entry.run.status == .running && entry.claimedAt == nil && now.timeIntervalSince(entry.run.updatedAt) > 120)
        )
    }

    private static func canContinue(_ entry: ComputerStoredRun, receiptID: UUID, in state: ServerState) -> Bool {
        entry.run.status == .running && entry.run.pendingCommandID == nil && entry.lastReceiptID == receiptID &&
            (entry.approvedUntil ?? .distantPast) > .now &&
            state.app.devices.contains { $0.id == entry.run.deviceID } &&
            state.app.devices.contains { $0.id == entry.run.requestedByDeviceID }
    }

    static func recover(in state: inout ServerState) {
        for id in (state.computerRuns ?? [:]).keys {
            guard var entry = state.computerRuns?[id], entry.run.status.isActive else { continue }
            entry.transition(.interrupted, message: "Aides restarted. Check the target window before resuming.")
            state.computerRuns?[id] = entry
        }
    }

    static func revoke(deviceID: UUID, in state: inout ServerState) {
        for id in (state.computerRuns ?? [:]).keys {
            guard var entry = state.computerRuns?[id], !entry.run.status.isTerminal,
                  canView(entry.run, deviceID: deviceID) else { continue }
            entry.transition(.stopped, message: "A participating device was revoked.")
            state.computerRuns?[id] = entry
        }
    }

    private static func canView(_ run: ComputerRun, deviceID: UUID) -> Bool {
        run.deviceID == deviceID || run.requestedByDeviceID == deviceID
    }

    private static func requirePaired(_ id: UUID, in state: ServerState) throws {
        guard state.app.devices.contains(where: { $0.id == id }) else { throw Abort(.unauthorized) }
    }

    private static func find(
        _ id: UUID, deviceID: UUID, in state: ServerState, targetOnly: Bool = false
    ) throws -> ComputerStoredRun {
        try requirePaired(deviceID, in: state)
        guard let entry = state.computerRuns?[id],
              targetOnly ? entry.run.deviceID == deviceID : canView(entry.run, deviceID: deviceID) else { throw Abort(.notFound) }
        return entry
    }
}
