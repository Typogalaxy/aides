import AidesCore
import AppKit
import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class ComputerUseRelay {
    private(set) var runs: [ComputerRun] = []
    private(set) var error: String?
    private(set) var isSending = false
    private(set) var isUnavailable = false
    private(set) var localPreview: ComputerRunPreview?
    private(set) var rememberedApprovals: [ComputerRememberedApproval] = []

    @ObservationIgnored private var client: ServerClient?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var grants: [UUID: Scope] = [:]
    @ObservationIgnored private var executors: [UUID: ComputerExecutor] = [:]
    @ObservationIgnored private var active: Active?
    @ObservationIgnored private var receipt: PendingReceipt?
    @ObservationIgnored private var seenCommandIDs: Set<UUID> = []
    @ObservationIgnored private var reviewedCommandIDs: [UUID: ReviewedCommand] = [:]
    @ObservationIgnored private var mutationGeneration = 0
    @ObservationIgnored private var sessionObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var recalledRunIDs: Set<UUID> = []
    @ObservationIgnored private var approvalStorageKey: String?
    @ObservationIgnored private var authorizationEpoch = UUID()
    @ObservationIgnored private var controlQueue: [UUID: RunControl] = [:]
    @ObservationIgnored private var controlTask: Task<Void, Never>?

    var hasLocalReview: Bool {
        guard let deviceID = client?.credential?.deviceID else { return false }
        return runs.contains {
            $0.deviceID == deviceID && ($0.status == .awaitingPermission || $0.status == .awaitingApproval)
        }
    }

    var activeLocalRun: ComputerRun? {
        guard let deviceID = client?.credential?.deviceID else { return nil }
        return runs.first { $0.deviceID == deviceID && $0.status.isActive }
    }

    func start(_ client: ServerClient) {
        stop()
        self.client = client
        if let deviceID = client.credential?.deviceID {
            let identity = client.endpoint.url.absoluteString + "\n" + deviceID.uuidString
            let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let key = "aides.computer-approvals.\(digest)"
            approvalStorageKey = key
            if let data = UserDefaults.standard.data(forKey: key),
               let saved = try? JSONDecoder().decode([ComputerRememberedApproval].self, from: data) {
                rememberedApprovals = Array(saved.prefix(32))
            }
        }
        let notifications = NSWorkspace.shared.notificationCenter
        sessionObservers = [
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.willSleepNotification
        ].map { name in
            notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.suspendForSessionChange() }
            }
        }
        let generation = self.generation
        poller = Task { [weak self] in
            while !Task.isCancelled, let self, self.generation == generation {
                let interval = await self.tick(client, generation: generation)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        generation = UUID()
        authorizationEpoch = UUID()
        for observer in sessionObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        sessionObservers.removeAll()
        poller?.cancel()
        controlTask?.cancel()
        controlTask = nil
        controlQueue.removeAll()
        active?.task.cancel()
        for executor in executors.values { executor.stop() }
        poller = nil
        active = nil
        receipt = nil
        grants.removeAll()
        executors.removeAll()
        seenCommandIDs.removeAll()
        reviewedCommandIDs.removeAll()
        mutationGeneration = 0
        recalledRunIDs.removeAll()
        rememberedApprovals.removeAll()
        approvalStorageKey = nil
        client = nil
        runs = []
        isSending = false
        isUnavailable = false
        localPreview = nil
        error = nil
    }

    @discardableResult
    func submit(
        id: UUID, deviceID: UUID, appIDs: [String], instruction: String, includeImages: Bool, threadID: UUID?, modelID: UUID?
    ) async -> Bool {
        await send(["runs"], NewRun(
            id: id, deviceID: deviceID, appIDs: appIDs, instruction: instruction, includeImages: includeImages,
            threadID: threadID, modelID: modelID
        )) != nil
    }

    func decidePermission(
        _ run: ComputerRun, approved: Bool, allowRoutineActions: Bool = false, allowBackground: Bool = false,
        remember: Bool = false, recalledApprovalID: UUID? = nil
    ) async {
        guard let deviceID = client?.credential?.deviceID, deviceID == run.deviceID,
              runs.contains(where: { $0.id == run.id && $0.status == .awaitingPermission }) else { return }
        if let recalledApprovalID {
            guard ComputerExecutor.sessionIsInteractive(), run.requiresFreshApproval != true,
                  rememberedApprovals.contains(where: { $0.id == recalledApprovalID && $0.matches(run) }) else { return }
        }
        if approved {
            guard ComputerExecutor.sessionIsInteractive() else {
                error = "Unlock this Mac and grant Accessibility access before allowing desktop interaction."
                return
            }
            let running = Set(ComputerExecutor.runningApps().map(\.id))
            guard run.appIDs.allSatisfy({ id in
                guard ComputerExecutor.isEligible(id) else { return false }
                if running.contains(id) { return true }
                guard !allowBackground, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return false }
                return url.isFileURL && url.pathExtension.lowercased() == "app" && Bundle(url: url)?.bundleIdentifier == id
            }) else {
                error = allowBackground
                    ? "Open the requested applications before allowing background use."
                    : "The requested applications are unavailable on this Mac."
                return
            }
        }
        let generation = self.generation
        let authorizationEpoch = self.authorizationEpoch
        let response = await send(
            ["runs", run.id.uuidString, "permission"],
            PermissionDecision(
                approved: approved, allowRoutineActions: approved && allowRoutineActions,
                allowBackground: approved && allowBackground
            )
        )
        guard self.generation == generation, let response else { return }
        if approved && response.status.acceptsDesktopCommands {
            guard self.authorizationEpoch == authorizationEpoch, ComputerExecutor.sessionIsInteractive(),
                  Set(response.appIDs) == Set(run.appIDs), response.includeImages == run.includeImages,
                  (response.allowBackground == true) == allowBackground,
                  recalledApprovalID.map({ id in rememberedApprovals.contains { $0.id == id } }) ?? true else {
                await control(response, .pause)
                return
            }
            grants[run.id] = Scope(
                appIDs: response.appIDs, includeImages: response.includeImages, allowBackground: allowBackground
            )
            if remember && !allowRoutineActions {
                saveApproval(for: run, allowBackground: allowBackground)
            }
        }
    }

    func forgetApproval(_ id: UUID) {
        rememberedApprovals.removeAll { $0.id == id }
        persistApprovals()
    }

    private func saveApproval(for run: ComputerRun, allowBackground: Bool) {
        guard approvalStorageKey != nil else { return }
        rememberedApprovals.removeAll { $0.matches(run) }
        rememberedApprovals.insert(ComputerRememberedApproval(
            requesterID: run.requestedByDeviceID, appIDs: run.appIDs.sorted(),
            includeImages: run.includeImages, allowBackground: allowBackground
        ), at: 0)
        rememberedApprovals = Array(rememberedApprovals.prefix(32))
        persistApprovals()
    }

    private func persistApprovals() {
        guard let approvalStorageKey else { return }
        if rememberedApprovals.isEmpty {
            UserDefaults.standard.removeObject(forKey: approvalStorageKey)
        } else if let data = try? JSONEncoder().encode(rememberedApprovals) {
            UserDefaults.standard.set(data, forKey: approvalStorageKey)
        }
    }

    func decideAction(_ run: ComputerRun, approved: Bool) async {
        guard let deviceID = client?.credential?.deviceID, deviceID == run.deviceID,
              !approved || grants[run.id] != nil, let actionID = run.pendingCommandID,
              runs.contains(where: {
                  $0.id == run.id && $0.status == .awaitingApproval && $0.pendingCommandID == actionID
              }) else { return }
        if approved {
            reviewedCommandIDs[actionID] = ReviewedCommand(
                runID: run.id, inputEpoch: ComputerExecutor.approvalInputEpoch()
            )
        }
        await send(["runs", run.id.uuidString, "decision"], ActionDecision(approved: approved, actionID: actionID))
    }

    func control(_ run: ComputerRun, _ action: RunControl) async {
        guard let client else { return }
        if run.deviceID == client.credential?.deviceID, action != .resume { revokeExecution(for: run.id) }
        if let queued = controlQueue[run.id], queued.priority > action.priority { return }
        controlQueue[run.id] = action
        mutationGeneration &+= 1
        if let controlTask {
            await controlTask.value
            return
        }
        let generation = self.generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.flushControls(using: client, generation: generation)
        }
        controlTask = task
        await task.value
    }

    private func flushControls(using client: ServerClient, generation: UUID) async {
        defer { if self.generation == generation { controlTask = nil } }
        while self.generation == generation, !Task.isCancelled,
              let (id, action) = controlQueue.max(by: { $0.value.priority < $1.value.priority }) {
            controlQueue.removeValue(forKey: id)
            do {
                let run: ComputerRun = try await client.post(
                    Self.route(["runs", id.uuidString, action.rawValue]), body: EmptyBody()
                )
                try requireGeneration(generation)
                mutationGeneration &+= 1
                apply(run)
            } catch is CancellationError {
                return
            } catch {
                if self.generation == generation { self.error = error.localizedDescription }
            }
        }
    }

    private func suspendForSessionChange() async {
        authorizationEpoch = UUID()
        let run = activeLocalRun
        for id in Array(grants.keys) { revokeExecution(for: id) }
        if let run { await control(run, .pause) }
    }

    private func tick(_ client: ServerClient, generation: UUID) async -> Duration {
        do {
            if let receipt, !isSending, controlTask == nil {
                do {
                    let _: ComputerRun = try await client.get(Self.route([
                        "runs", receipt.runID.uuidString, "commands", receipt.payload.commandID.uuidString,
                    ]))
                    try requireGeneration(generation)
                    guard !isSending, controlTask == nil else { return .milliseconds(250) }
                    guard self.receipt?.payload.commandID == receipt.payload.commandID,
                          grants[receipt.runID] != nil else { return .milliseconds(250) }
                    let updated: ComputerRun = try await client.post(
                        Self.route(["runs", receipt.runID.uuidString, "receipt"]), body: receipt.payload
                    )
                    try requireGeneration(generation)
                    if self.receipt?.payload.commandID == receipt.payload.commandID {
                        self.receipt = nil
                        if !isSending { apply(updated) }
                    }
                } catch ServerError.response(let status, _) where [400, 404, 409, 410, 413, 422].contains(status) {
                    try requireGeneration(generation)
                    if self.receipt?.payload.commandID == receipt.payload.commandID {
                        revokeExecution(for: receipt.runID)
                        error = "The server could not accept the last Desktop action receipt. Check the application before resuming."
                    }
                }
            }
            let mutationGeneration = self.mutationGeneration
            let updated: [ComputerRun] = try await client.get(Self.route(["runs"]))
            try requireGeneration(generation)
            guard self.mutationGeneration == mutationGeneration, !isSending, controlTask == nil else { return .milliseconds(250) }
            if let deviceID = client.credential?.deviceID {
                let previous = localReviewIDs(in: runs, deviceID: deviceID)
                if !localReviewIDs(in: updated, deviceID: deviceID).isSubset(of: previous) {
                    NSApp.requestUserAttention(.informationalRequest)
                }
            }
            runs = updated
            isUnavailable = false
            reconcile()
            if activeLocalRun == nil, active == nil, receipt == nil,
               ComputerExecutor.sessionIsInteractive(),
               let deviceID = client.credential?.deviceID,
               let (run, approval) = recalledApproval(in: updated, deviceID: deviceID) {
                recalledRunIDs.insert(run.id)
                await decidePermission(run, approved: true, allowBackground: approval.allowBackground, recalledApprovalID: approval.id)
                return .milliseconds(350)
            }
            guard active == nil, receipt == nil, !isSending,
                  let deviceID = client.credential?.deviceID,
                  updated.contains(where: { $0.deviceID == deviceID && grants[$0.id] != nil && $0.status.acceptsDesktopCommands }) else {
                return active == nil ? .seconds(2) : .milliseconds(450)
            }

            let next: ComputerClaim = try await client.post(Self.route(["next"]), body: EmptyBody())
            try requireGeneration(generation)
            guard let command = next.command else { return .milliseconds(700) }
            guard seenCommandIDs.insert(command.id).inserted else { return .seconds(1) }
            let scope = Scope(
                appIDs: command.appIDs, includeImages: command.includeImages, allowBackground: command.allowBackground
            )
            guard grants[command.runID] == scope else {
                refuse(command)
                return .milliseconds(100)
            }
            let checked: ComputerRun
            do {
                checked = try await client.get(
                    Self.route(["runs", command.runID.uuidString, "commands", command.id.uuidString])
                )
            } catch ServerError.response(let status, _) where [404, 409, 410].contains(status) {
                try requireGeneration(generation)
                revokeExecution(for: command.runID)
                return .milliseconds(250)
            }
            try requireGeneration(generation)
            guard !isSending, controlTask == nil, grants[command.runID] == scope, checked.deviceID == deviceID,
                  checked.id == command.runID, checked.status.acceptsDesktopCommands else {
                refuse(command)
                return .milliseconds(100)
            }
            launch(command, generation: generation)
            return .milliseconds(400)
        } catch is CancellationError {
            return .seconds(1)
        } catch let failure as ServerError where failure.isUnauthorized {
            guard generation == self.generation else { return .seconds(1) }
            stop()
            return .seconds(10)
        } catch ServerError.response(404, _) {
            guard generation == self.generation else { return .seconds(1) }
            isUnavailable = true
            return .seconds(10)
        } catch {
            guard generation == self.generation else { return .seconds(1) }
            if let active { revokeExecution(for: active.runID) }
            return .seconds(2)
        }
    }

    private func launch(_ command: ComputerCommand, generation: UUID) {
        let executor = executors[command.runID] ?? ComputerExecutor(
            allowedAppIDs: command.appIDs, includeImages: command.includeImages, allowBackground: command.allowBackground
        )
        executors[command.runID] = executor
        if let review = reviewedCommandIDs.removeValue(forKey: command.id), review.runID == command.runID {
            executor.acknowledgeReviewedAction(inputEpoch: review.inputEpoch)
        }
        let task = Task { [weak self] in
            let payload: ActionReceipt
            do {
                try Task.checkCancellation()
                let observation = try await executor.execute(command.action)
                try Task.checkCancellation()
                payload = ActionReceipt(commandID: command.id, observation: observation)
            } catch is CancellationError {
                payload = ActionReceipt(commandID: command.id, error: "Desktop interaction paused. Check what was applied before continuing.")
            } catch {
                payload = ActionReceipt(
                    commandID: command.id, error: String(error.localizedDescription.prefix(220))
                )
            }
            guard let self, self.generation == generation, self.active?.commandID == command.id,
                  self.grants[command.runID] != nil else { return }
            if let observation = payload.observation, let image = observation.screenshot,
               self.grants[command.runID]?.includeImages == true {
                self.localPreview = ComputerRunPreview(runID: command.runID, appID: observation.appID, image: image)
            } else if self.localPreview?.runID == command.runID {
                self.localPreview = nil
            }
            self.receipt = PendingReceipt(runID: command.runID, payload: payload)
            self.active = nil
        }
        active = Active(runID: command.runID, commandID: command.id, task: task)
    }

    private func refuse(_ command: ComputerCommand) {
        revokeExecution(for: command.runID)
        error = "Desktop access is no longer approved on this Mac."
    }

    private func revokeExecution(for id: UUID) {
        authorizationEpoch = UUID()
        if active?.runID == id {
            active?.task.cancel()
            active = nil
        }
        if receipt?.runID == id { receipt = nil }
        executors.removeValue(forKey: id)?.stop()
        if localPreview?.runID == id { localPreview = nil }
        grants.removeValue(forKey: id)
        reviewedCommandIDs = reviewedCommandIDs.filter { $0.value.runID != id }
    }

    private func recalledApproval(in runs: [ComputerRun], deviceID: UUID) -> (ComputerRun, ComputerRememberedApproval)? {
        for run in runs.reversed()
        where run.deviceID == deviceID && run.status == .awaitingPermission
            && run.requiresFreshApproval != true && !recalledRunIDs.contains(run.id) {
            if let approval = rememberedApprovals.first(where: { $0.matches(run) }) { return (run, approval) }
        }
        return nil
    }

    private func localReviewIDs(in runs: [ComputerRun], deviceID: UUID) -> Set<UUID> {
        Set(runs.compactMap { run in
            guard run.deviceID == deviceID else { return nil }
            if run.status == .awaitingPermission { return run.id }
            if run.status == .awaitingApproval { return run.pendingCommandID }
            return nil
        })
    }

    private func reconcile() {
        recalledRunIDs.formIntersection(runs.filter { !$0.status.isTerminal }.map(\.id))
        for id in Array(grants.keys) {
            guard let run = runs.first(where: { $0.id == id }) else {
                revokeExecution(for: id)
                continue
            }
            if !run.status.acceptsDesktopCommands {
                switch run.status {
                case .awaitingApproval:
                    // Keep the current observation for its pending, user-reviewed action.
                    break
                default:
                    revokeExecution(for: id)
                }
            }
        }
        if grants.isEmpty, active == nil, receipt == nil {
            seenCommandIDs.removeAll()
        }
    }

    @discardableResult
    private func send<Body: Encodable & Sendable>(_ path: [String], _ body: Body) async -> ComputerRun? {
        guard let client, !isSending else { return nil }
        let generation = self.generation
        isSending = true
        mutationGeneration &+= 1
        error = nil
        defer {
            if self.generation == generation {
                isSending = false
                mutationGeneration &+= 1
            }
        }
        do {
            let run: ComputerRun = try await client.post(Self.route(path), body: body)
            try requireGeneration(generation)
            apply(run)
            return run
        } catch is CancellationError {
            return nil
        } catch {
            if self.generation == generation { self.error = error.localizedDescription }
            return nil
        }
    }

    private func apply(_ run: ComputerRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.insert(run, at: 0)
        }
    }

    private func requireGeneration(_ generation: UUID) throws {
        guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
    }

    private static func route(_ path: [String]) -> [String] { ["toolkit", "computer"] + path }
}

private extension ComputerRunStatus {
    var acceptsDesktopCommands: Bool { self == .queued || self == .running }
}

struct ComputerRememberedApproval: Codable, Identifiable, Sendable {
    var id = UUID()
    let requesterID: UUID
    let appIDs: [String]
    let includeImages: Bool
    let allowBackground: Bool

    func matches(_ run: ComputerRun) -> Bool {
        requesterID == run.requestedByDeviceID && appIDs == run.appIDs.sorted() && includeImages == run.includeImages
    }
}

struct ComputerRunPreview {
    let runID: UUID
    let appID: String
    let image: Data
}

enum RunControl: String {
    case pause, resume, stop

    var priority: Int {
        switch self {
        case .resume: 0
        case .pause: 1
        case .stop: 2
        }
    }
}

private struct Scope: Equatable {
    let appIDs: [String]
    let includeImages: Bool
    let allowBackground: Bool
}

private struct ReviewedCommand {
    let runID: UUID
    let inputEpoch: TimeInterval
}

private struct Active {
    let runID: UUID
    let commandID: UUID
    let task: Task<Void, Never>
}

private struct PendingReceipt {
    let runID: UUID
    let payload: ActionReceipt
}

private struct NewRun: Encodable, Sendable {
    let id: UUID
    let deviceID: UUID
    let appIDs: [String]
    let instruction: String
    let includeImages: Bool
    let threadID: UUID?
    let modelID: UUID?
}

private struct EmptyBody: Encodable, Sendable {}

private struct PermissionDecision: Encodable, Sendable {
    let approved: Bool
    let allowRoutineActions: Bool
    let allowBackground: Bool
}

private struct ActionDecision: Encodable, Sendable {
    let approved: Bool
    let actionID: UUID
}

private struct ActionReceipt: Encodable, Sendable {
    let commandID: UUID
    var observation: ComputerObservation?
    var error: String?
}
