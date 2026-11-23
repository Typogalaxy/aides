import AidesCore
import AppKit
@preconcurrency import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

struct ComputerUseView: View {
    let workspace: Workspace

    @ViewState private var showsNewRun = false
    @ViewState private var showsDirectControls = false
    @ViewState private var review: ComputerReview?
    @ViewState private var allowRoutineActions = false
    @ViewState private var allowBackground = false
    @ViewState private var rememberPermission = false

    private var relay: ComputerUseRelay { workspace.computerRelay }

    var body: some View {
        Form {
            Section("Computer Use") {
                ComputerActionRow {
                    Button("Start task…") { showsNewRun = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(relay.isUnavailable || relay.isSending)
                    Button("Direct controls…") { showsDirectControls = true }
                }
                Text("An Aides task can inspect and operate approved applications on a paired Mac. The target Mac must remain connected and approve access.")
                    .desktopUIFont(.caption)
                    .foregroundStyle(.secondary)
                if relay.isUnavailable {
                    Text("This server build does not support Computer Use.").foregroundStyle(.secondary)
                }
                if let error = relay.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            Section("Capture the current app") {
                Toggle("Enable capture shortcut", isOn: Binding(
                    get: { workspace.appshots.isEnabled },
                    set: { workspace.appshots.changeEnabled($0) }
                ))
                if workspace.appshots.isEnabled {
                    Toggle("Include a window screenshot", isOn: Binding(
                        get: { workspace.appshots.includeImages },
                        set: { workspace.appshots.includeImages = $0 }
                    ))
                    Text("Press \(ComputerAppshotCapture.shortcut) in the target app. Review the attached window in Aides before you send it.")
                        .desktopUIFont(.caption)
                        .foregroundStyle(.secondary)
                    ComputerActionRow {
                        Button("Enable Accessibility…") { promptAccessibility() }
                        if workspace.appshots.includeImages {
                            Button("Enable Screen Recording…") { _ = CGRequestScreenCaptureAccess() }
                        }
                    }
                    .desktopUIFont(.caption)
                }
                if let error = workspace.appshots.error {
                    Text(error).desktopUIFont(.caption).foregroundStyle(.orange)
                }
            }
            if !relay.rememberedApprovals.isEmpty {
                Section("Remembered on this Mac") {
                    ForEach(relay.rememberedApprovals) { approval in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(workspace.toolkitDeviceName(approval.requesterID))
                            Text(approval.appIDs.joined(separator: ", "))
                                .desktopUIFont(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(approvalSummary(approval)).desktopUIFont(.caption).foregroundStyle(.secondary)
                            Button("Forget", role: .destructive) { relay.forgetApproval(approval.id) }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section("Tasks") {
                if relay.runs.isEmpty {
                    Text("No Computer Use tasks yet.").foregroundStyle(.secondary)
                }
                ForEach(relay.runs, id: \.id) { run in
                    taskRow(run)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsNewRun) { NewComputerUseSheet(workspace: workspace) }
        .sheet(isPresented: $showsDirectControls) {
            VStack(alignment: .trailing, spacing: 0) {
                ToolkitComputerView()
                Button("Done") { showsDirectControls = false }
                    .keyboardShortcut(.cancelAction)
                    .padding()
            }
            .frame(idealWidth: 560, maxWidth: 620, idealHeight: 460, maxHeight: 660)
        }
        .sheet(item: $review) { review in reviewSheet(review) }
    }

    private func taskRow(_ run: ComputerRun) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(run.instruction).lineLimit(3).textSelection(.enabled)
            Text(run.status.displayName).desktopUIFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            Text("\(workspace.toolkitDeviceName(run.deviceID)) · \(run.appIDs.joined(separator: ", "))")
                .desktopUIFont(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let message = run.message {
                Text(message).desktopUIFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let result = run.result {
                DisclosureGroup("Result") { Text(result).textSelection(.enabled) }
            }
            if !run.steps.isEmpty {
                DisclosureGroup("Activity (\(run.steps.count))") {
                    ForEach(run.steps, id: \.number) { step in
                        ComputerDetailRow(step.kind.displayName, value: step.appID ?? "Desktop")
                            .desktopUIFont(.caption)
                    }
                }
            }
            controls(run)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func controls(_ run: ComputerRun) -> some View {
        ComputerActionRow {
            if run.deviceID == workspace.deviceID && run.status == .awaitingPermission {
                Button("Review app access…") {
                    allowRoutineActions = false
                    allowBackground = false
                    rememberPermission = false
                    review = .permission(run)
                }
                .buttonStyle(.borderedProminent)
                .disabled(relay.isSending)
            }
            if run.deviceID == workspace.deviceID && run.status == .awaitingApproval, let action = run.pendingAction {
                Button("Review action…") { review = .action(run, action) }
                    .buttonStyle(.borderedProminent)
                .disabled(relay.isSending)
            }
            if run.status == .queued || run.status == .running || run.status == .awaitingApproval {
                Button(run.deviceID == workspace.deviceID ? "Take over" : "Pause") {
                    Task { await relay.control(run, .pause) }
                }
            }
            if run.status == .paused || run.status == .interrupted {
                Button("Request resume") { Task { await relay.control(run, .resume) } }
            }
            if run.status.canStop {
                Button("Stop", role: .destructive) { Task { await relay.control(run, .stop) } }
            }
        }
    }

    private func reviewSheet(_ review: ComputerReview) -> some View {
        ComputerReviewSheet(title: review.title) {
            ComputerDetailRow("Requested from", value: workspace.toolkitDeviceName(review.run.requestedByDeviceID))
            Text(review.run.instruction).textSelection(.enabled)
            switch review {
            case .permission(let run):
                Text(run.appIDs.joined(separator: "\n")).monospaced().textSelection(.enabled)
                Text(run.includeImages
                     ? "The selected app's window and accessible text can be sent to the Mac running your local model."
                     : "Accessible window information can be sent to the Mac running your local model.")
                    .foregroundStyle(.secondary)
                Toggle("Allow routine text entry and navigation in TextEdit for this task", isOn: $allowRoutineActions)
                    .onChange(of: allowRoutineActions) { _, newValue in
                        if newValue { rememberPermission = false }
                    }
                let readyForBackground = Set(run.appIDs).isSubset(of: Set(ComputerExecutor.runningApps().map(\.id)))
                Toggle("Allow supported controls to run in the background", isOn: $allowBackground)
                    .disabled(run.includeImages || !readyForBackground)
                if run.includeImages {
                    Text("Background mode is available for tasks that use accessibility information only.")
                        .desktopUIFont(.caption).foregroundStyle(.secondary)
                } else if !readyForBackground {
                    Text("Open the selected apps before enabling background use.")
                        .desktopUIFont(.caption).foregroundStyle(.secondary)
                }
                if allowBackground {
                    Text("Background mode uses accessibility controls and keeps the pointer and keyboard available.")
                        .desktopUIFont(.caption).foregroundStyle(.secondary)
                }
                Toggle("Remember app access for this Mac and requester", isOn: $rememberPermission)
                    .disabled(allowRoutineActions)
                if rememberPermission {
                    Text("Future tasks with this same requester, app list and capture setting may start while this Mac is unlocked. Desktop actions still require review.")
                        .desktopUIFont(.caption).foregroundStyle(.secondary)
                }
                ComputerActionRow {
                    Button("Enable Accessibility…") { promptAccessibility() }
                    if run.includeImages {
                        Button("Enable Screen Recording…") { _ = CGRequestScreenCaptureAccess() }
                    }
                }
                .desktopUIFont(.caption)
            case .action(let run, let action):
                ComputerDetailRow("Action", value: action.kind.displayName)
                if let app = action.appID { ComputerDetailRow("App", value: app) }
                if let window = run.pendingReview?.windowTitle, !window.isEmpty {
                    ComputerDetailRow("Window", value: window)
                }
                if let key = action.key { ComputerDetailRow("Key", value: key) }
                if let button = action.button { ComputerDetailRow("Pointer button", value: button.rawValue.capitalized) }
                if let count = action.clickCount { ComputerDetailRow("Clicks", value: String(count)) }
                if let label = run.pendingReview?.label, !label.isEmpty {
                    ComputerDetailRow("Control", value: label)
                } else if let role = run.pendingReview?.role {
                    ComputerDetailRow("Control", value: role)
                }
                if let element = action.elementID { ComputerDetailRow("Element reference", value: element) }
                if let x = action.x, let y = action.y {
                    ComputerDetailRow(action.kind == .drag ? "Start position" : "Window position", value: position(x, y))
                }
                if let x = action.endX, let y = action.endY {
                    ComputerDetailRow("End position", value: position(x, y))
                }
                if let dx = action.deltaX, let dy = action.deltaY {
                    ComputerDetailRow("Scroll direction and steps", value: "Horizontal \(dx), vertical \(dy)")
                }
                if let preview = relay.localPreview, preview.runID == run.id, preview.appID == action.appID,
                   let image = NSImage(data: preview.image) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 160, alignment: .leading)
                        .accessibilityLabel("Last observed window")
                }
                if let text = action.text {
                    Text(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        } actions: {
            ComputerActionRow(alignment: .trailing) {
                Button("Close") { self.review = nil }.keyboardShortcut(.cancelAction)
                Button("Decline", role: .destructive) { decide(review, approved: false) }
                Button("Allow") { decide(review, approved: true) }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(relay.isSending)
        }
    }

    private func approvalSummary(_ approval: ComputerRememberedApproval) -> String {
        if approval.allowBackground { return "Background accessibility access" }
        return approval.includeImages ? "Window text and screenshots" : "Window text"
    }

    private func position(_ x: Double, _ y: Double) -> String {
        "\(x.formatted(.percent.precision(.fractionLength(0)))) × \(y.formatted(.percent.precision(.fractionLength(0))))"
    }

    private func decide(_ item: ComputerReview, approved: Bool) {
        let routine = allowRoutineActions
        let background = allowBackground
        let remember = rememberPermission
        review = nil
        Task {
            switch item {
            case .permission(let run):
                await relay.decidePermission(
                    run, approved: approved, allowRoutineActions: routine, allowBackground: background, remember: remember
                )
            case .action(let run, _):
                await relay.decideAction(run, approved: approved)
            }
        }
    }

    private func promptAccessibility() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }
}

private enum ComputerReview: Identifiable {
    case permission(ComputerRun)
    case action(ComputerRun, ComputerAction)

    var id: UUID { run.id }

    var run: ComputerRun {
        switch self {
        case .permission(let run), .action(let run, _): run
        }
    }

    var title: String {
        switch self {
        case .permission: "Allow app access for this task?"
        case .action: "Allow this desktop action?"
        }
    }
}

struct NewComputerUseSheet: View {
    let workspace: Workspace
    let threadID: UUID?

    @Environment(\.dismiss) private var dismiss
    @ViewState private var deviceID: UUID?
    @ViewState private var modelID: UUID?
    @ViewState private var localChoices: [ComputerApp] = []
    @ViewState private var installedChoices: [ComputerApp] = []
    @ViewState private var primaryAppID: String?
    @ViewState private var includedApps: Set<String> = []
    @ViewState private var remoteApps = ""
    @ViewState private var instruction: String
    @ViewState private var includeImages = false
    @ViewState private var pendingSubmission: Submission?

    init(workspace: Workspace, instruction: String = "", threadID: UUID? = nil) {
        self.workspace = workspace
        self.threadID = threadID
        _instruction = ViewState(initialValue: instruction)
    }

    private var isLocal: Bool { deviceID != nil && deviceID == workspace.deviceID }
    private var appIDs: [String] {
        if isLocal {
            var ids = localChoices.map(\.id).filter(includedApps.contains)
            if let primaryAppID, let index = ids.firstIndex(of: primaryAppID), index > 0 {
                let first = ids.remove(at: index)
                ids.insert(first, at: 0)
            }
            return ids
        }
        return remoteApps.split { $0 == "," || $0.isWhitespace }.map(String.init)
    }

    private var localModels: [ModelProfile] { workspace.state.models.filter { $0.kind == .ollama } }

    private var canStart: Bool {
        let task = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return deviceID != nil && (1...5).contains(appIDs.count) && Set(appIDs).count == appIDs.count &&
            appIDs.allSatisfy(ComputerApp.isEligible) && (1...2_000).contains(task.count) &&
            localModels.contains(where: { $0.id == (modelID ?? workspace.state.settings.defaultModelID) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeading("Start a Computer Use task")
            Form {
                Picker("Run on", selection: $deviceID) {
                    Text("Choose a paired Mac").tag(UUID?.none)
                    ForEach(workspace.state.devices) { device in
                        Text(workspace.toolkitDeviceName(device.id)).tag(Optional(device.id))
                    }
                }
                if isLocal {
                    ComputerActionRow {
                        Button("Refresh running apps", action: refreshApps)
                        Button("Choose installed app…", action: chooseInstalledApp)
                    }
                    if localChoices.isEmpty {
                        Text("Open or choose an application.").foregroundStyle(.secondary)
                    }
                    ForEach(localChoices, id: \.id) { app in
                        Toggle(app.name, isOn: Binding(
                            get: { includedApps.contains(app.id) },
                            set: { checked in
                                if checked { includedApps.insert(app.id) } else { includedApps.remove(app.id) }
                            }
                        ))
                    }
                    if includedApps.count > 1 {
                        Picker("First app to inspect", selection: $primaryAppID) {
                            Text("First selected app").tag(String?.none)
                            ForEach(localChoices.filter { includedApps.contains($0.id) }) { app in
                                Text(app.name).tag(Optional(app.id))
                            }
                        }
                    }
                } else if deviceID != nil {
                    TextField("App bundle IDs", text: $remoteApps, prompt: Text("com.apple.TextEdit"))
                    Text("Enter up to five installed app bundle IDs, separated by commas in the order you want them inspected. Review and allow them on the target Mac.")
                        .desktopUIFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Local model", selection: $modelID) {
                    Text("Default").tag(UUID?.none)
                    ForEach(localModels) { model in Text(model.name).tag(Optional(model.id)) }
                }
                TextField("Task", text: $instruction, prompt: Text("Describe the result you want"), axis: .vertical)
                    .lineLimit(3...6)
                Toggle("Share window snapshots with the local model", isOn: $includeImages)
                if includeImages {
                    Text("Choose an Ollama model that accepts images.")
                        .desktopUIFont(.caption).foregroundStyle(.secondary)
                }
                if localModels.isEmpty {
                    Text("Configure a local Ollama model in Settings to run desktop tasks.")
                        .desktopUIFont(.caption).foregroundStyle(.secondary)
                }
                if let error = workspace.computerRelay.error {
                    Text(error).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            ComputerActionRow(alignment: .trailing) {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Request app access") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart || workspace.computerRelay.isSending)
            }
        }
        .padding(22)
        .frame(idealWidth: 520, maxWidth: 600, idealHeight: 490, maxHeight: 680)
        .task {
            deviceID = workspace.deviceID
            refreshApps()
        }
    }

    private func refreshApps() {
        let running = ComputerExecutor.runningApps()
        let runningIDs = Set(running.map(\.id))
        localChoices = (running + installedChoices.filter { !runningIDs.contains($0.id) })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        includedApps.formIntersection(localChoices.map(\.id))
        if let primaryAppID, !includedApps.contains(primaryAppID) { self.primaryAppID = nil }
    }

    private func chooseInstalledApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an installed application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url, let bundle = Bundle(url: url),
                  let id = bundle.bundleIdentifier, ComputerExecutor.isEligible(id),
                  NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.resolvingSymlinksInPath() ==
                    url.resolvingSymlinksInPath() else { return }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            if !installedChoices.contains(where: { $0.id == id }) {
                installedChoices.append(ComputerApp(id: id, name: name))
            }
            includedApps.insert(id)
            refreshApps()
        }
    }

    private func submit() {
        guard let deviceID, canStart else { return }
        let draft = Submission(
            deviceID: deviceID, appIDs: appIDs, instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines),
            includeImages: includeImages, modelID: modelID
        )
        let request: Submission
        if let pendingSubmission, pendingSubmission.matches(draft) {
            request = pendingSubmission
        } else {
            pendingSubmission = draft
            request = draft
        }
        Task {
            if await workspace.computerRelay.submit(
                id: request.id, deviceID: request.deviceID, appIDs: request.appIDs,
                instruction: request.instruction, includeImages: request.includeImages, threadID: threadID, modelID: request.modelID
            ) { dismiss() }
        }
    }
}

struct ComputerActionRow<Content: View>: View {
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: alignment, spacing: 8) { content }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

struct ComputerDetailRow: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                valueText
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                valueText
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var valueText: some View {
        Text(value)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ComputerReviewSheet<Content: View, Actions: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageHeading(title)
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            actions.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(idealWidth: 510, maxWidth: 620, idealHeight: 470, maxHeight: 660)
    }
}

private struct Submission {
    let id = UUID()
    let deviceID: UUID
    let appIDs: [String]
    let instruction: String
    let includeImages: Bool
    let modelID: UUID?

    func matches(_ other: Submission) -> Bool {
        deviceID == other.deviceID && appIDs == other.appIDs && instruction == other.instruction &&
            includeImages == other.includeImages && modelID == other.modelID
    }
}

extension ComputerRunStatus {
    var displayName: String {
        switch self {
        case .awaitingPermission: "Awaiting app access"
        case .queued: "Queued"
        case .running: "Running"
        case .awaitingApproval: "Awaiting action approval"
        case .paused: "Paused"
        case .completed: "Completed"
        case .stopped: "Stopped"
        case .interrupted: "Interrupted"
        case .failed: "Failed"
        }
    }

    var canStop: Bool {
        switch self {
        case .awaitingPermission, .queued, .running, .awaitingApproval, .paused, .interrupted: true
        case .completed, .stopped, .failed: false
        }
    }
}

private extension ComputerActionKind {
    var displayName: String {
        switch self {
        case .observe: "Inspect window"
        case .activate: "Activate app"
        case .click: "Click"
        case .typeText: "Enter text"
        case .key: "Press key"
        case .scroll: "Scroll"
        case .drag: "Drag"
        case .movePointer: "Move pointer"
        case .finish: "Finish"
        case .handoff: "Hand over control"
        }
    }
}
