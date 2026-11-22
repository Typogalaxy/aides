import AidesCore
import SwiftUI

extension Color {
    static let aidesAccent = Color(red: 0.25, green: 0.47, blue: 0.66)
}

enum WorkspacePage: String, CaseIterable, Identifiable {
    case conversations, projects, workers, activity, settings

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .conversations: "bubble.left.and.bubble.right"
        case .projects: "folder"
        case .workers: "gearshape.2"
        case .activity: "chart.bar.xaxis"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    let updates: DesktopUpdates

    @ViewState private var page = WorkspacePage.conversations
    @ViewState private var settingsPane = SettingsPane.models
    @ViewState private var toolkitPane = ToolkitPane.files
    @ViewState private var conversationID: UUID?
    @ViewState private var projectID: UUID?
    @ViewState private var inspectorTaskID: UUID?
    @ViewState private var drafts: [UUID: String] = [:]
    @ViewState private var showsNewConversation = false
    @ViewState private var showsConversationSidebar = true

    var body: some View {
        Group {
            if workspace.isConnected {
                connectedView
            } else {
                ConnectionView(workspace: workspace)
                    .overlay(alignment: .bottomTrailing) {
                        if updates.hasUpdate {
                            Button("Update available", action: updates.check)
                                .buttonStyle(.borderedProminent)
                                .padding()
                        }
                    }
            }
        }
        .tint(.aidesAccent)
        .alert("Aides", isPresented: Binding(
            get: { workspace.error != nil },
            set: { if !$0 { workspace.error = nil } }
        )) {
            Button("OK") { workspace.error = nil }
        } message: {
            Text(workspace.error ?? "")
        }
        .sheet(isPresented: $showsNewConversation) {
            NewConversationSheet(workspace: workspace) { id in
                page = .conversations
                conversationID = id
            }
        }
    }

    private var connectedView: some View {
        HStack(spacing: 0) {
            navigationRail
            Divider()
            if page == .conversations && showsConversationSidebar {
                ConversationSidebar(
                    conversations: workspace.state.threads,
                    projects: workspace.state.projects,
                    selection: $conversationID,
                    newConversation: { showsNewConversation = true }
                )
                .frame(width: 244)
                Divider()
            }
            VStack(spacing: 0) {
                if let message = workspace.connectionError {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.slash")
                        Text(message)
                    }
                    .desktopUIFont(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(9)
                    .background(.orange.opacity(0.13))
                    Divider()
                }
                HStack(spacing: 0) {
                    mainContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let inspectorTask {
                        Divider()
                        WorkerInspector(workspace: workspace, task: inspectorTask) { inspectorTaskID = nil }
                            .frame(width: 306)
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onChange(of: workspace.state.threads.map(\.id), initial: true) { _, ids in
            if let conversationID, ids.contains(conversationID) { return }
            conversationID = workspace.state.threads.first { $0.role == .secretary }?.id ?? ids.first
        }
        .onChange(of: page) { _, _ in inspectorTaskID = nil }
        .onChange(of: workspace.appshots.draft?.id) { _, id in
            guard id != nil else { return }
            page = .conversations
            if workspace.state.threads.first(where: { $0.id == conversationID })?.archivedAt != nil {
                conversationID = workspace.state.threads.first { $0.role == .secretary }?.id
            }
        }
    }

    private var inspectorTask: WorkItem? {
        workspace.state.tasks.first { $0.id == inspectorTaskID }
    }

    private var navigationRail: some View {
        VStack(spacing: 8) {
            railButton(
                showsConversationSidebar ? "Hide conversation sidebar" : "Show conversation sidebar",
                icon: "sidebar.left"
            ) {
                showsConversationSidebar.toggle()
            }
            .disabled(page != .conversations)
            .keyboardShortcut("s", modifiers: [.command, .control])

            Divider().padding(.horizontal, 5)
            ForEach(WorkspacePage.allCases.filter { $0 != .settings }) { destination in
                destinationButton(destination)
            }
            Spacer(minLength: 8)

            if workspace.fileRelay.pendingMove != nil {
                railButton("Review file change", icon: "doc.badge.ellipsis") {
                    page = .settings
                    toolkitPane = .files
                    settingsPane = .toolkit
                }
            }
            if workspace.computerRelay.hasLocalReview {
                railButton("Review desktop task", icon: "exclamationmark.triangle", highlighted: true,
                           action: showComputerUse)
            }
            if let run = workspace.computerRelay.activeLocalRun {
                railButton("Pause desktop task", icon: "pause.circle") {
                    Task { await workspace.computerRelay.control(run, .pause) }
                }
            }
            if updates.hasUpdate {
                railButton("Update available", icon: "arrow.down.circle", highlighted: true, action: updates.check)
            }

            destinationButton(.settings)

            let isConnected = workspace.connectionError == nil
            let status = isConnected ? "Server connected" : "Reconnecting"
            Circle()
                .fill(isConnected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .frame(width: 34, height: 26)
                .help(status)
                .accessibilityLabel(status)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 12)
        .frame(width: 52)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func destinationButton(_ destination: WorkspacePage) -> some View {
        let approvalCount = destination == .workers
            ? workspace.state.tasks.count { $0.status == .waitingApproval }
            : 0
        let title = approvalCount > 0 ? "\(destination.title), \(approvalCount) awaiting approval" : destination.title
        return railButton(title, icon: destination.icon, highlighted: page == destination) {
            page = destination
        }
        .overlay(alignment: .topTrailing) {
            if approvalCount > 0 {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .padding(4)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityAddTraits(page == destination ? .isSelected : [])
    }

    private func railButton(
        _ title: String,
        icon: String,
        highlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .desktopUIFont(.title3, weight: .medium)
                .foregroundStyle(highlighted ? Color.aidesAccent : Color.secondary)
                .frame(width: 36, height: 35)
                .background(highlighted ? Color.aidesAccent.opacity(0.15) : .clear, in: .rect(cornerRadius: 9))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch page {
        case .conversations:
            conversationsView
        case .projects:
            ProjectsView(workspace: workspace, selection: $projectID) { id in
                page = .conversations
                conversationID = id
            } showWorker: { id in
                inspectorTaskID = id
            }
        case .workers:
            WorkersView(workspace: workspace) { inspectorTaskID = $0 }
        case .activity:
            ActivityView(state: workspace.state)
        case .settings:
            SettingsView(workspace: workspace, updates: updates, pane: $settingsPane, toolkitPane: $toolkitPane)
        }
    }

    @ViewBuilder
    private var conversationsView: some View {
        if let current = workspace.state.threads.first(where: { $0.id == conversationID }) {
            ChatView(
                workspace: workspace,
                conversation: current,
                draft: Binding(
                    get: { drafts[current.id, default: ""] },
                    set: { drafts[current.id] = $0 }
                ),
                showWorker: { inspectorTaskID = $0 },
                showComputerUse: showComputerUse
            )
            .id(current.id)
        } else {
            ContentUnavailableView {
                Label("No conversation selected", systemImage: "bubble.left")
            } actions: {
                Button("New conversation") { showsNewConversation = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func showComputerUse() {
        page = .settings
        toolkitPane = .computer
        settingsPane = .toolkit
    }
}

struct ConnectionView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(Color.aidesAccent)
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect to Aides").desktopUIFont(.largeTitle, weight: .semibold)
                Text("Pair this Mac with the server that holds your conversations and projects.")
                    .foregroundStyle(.secondary)
            }
            if LocalService.isBundled {
                Button {
                    Task { await workspace.startLocalService() }
                } label: {
                    Label("Start local server and pair", systemImage: "desktopcomputer")
                }
                .buttonStyle(.borderedProminent)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Server address")
                    TextField("https://server.example.net", text: $workspace.address)
                        .accessibilityLabel("Server address")
                }
                GridRow {
                    Text("Device name")
                    TextField("MacBook", text: $workspace.deviceName)
                        .accessibilityLabel("Device name")
                }
                GridRow {
                    Text("Pairing code")
                    SecureField("Pairing code", text: $workspace.inviteCode)
                        .accessibilityLabel("Pairing code")
                }
            }
            .textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                Button("Pair device") { Task { await workspace.pair() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(workspace.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Reconnect") { Task { await workspace.reconnect() } }
                if workspace.isWorking { ProgressView().controlSize(.small) }
            }
            Text("Create a code in Settings on an already paired Mac, or run AidesServer invite on your server.")
                .desktopUIFont(.callout)
                .foregroundStyle(.secondary)
        }
        .disabled(workspace.isWorking)
        .frame(maxWidth: 455)
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PageHeading: View {
    let title: String
    let description: String?

    init(_ title: String, description: String? = nil) {
        self.title = title
        self.description = description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).desktopUIFont(.title2, weight: .semibold)
            if let description {
                Text(description).desktopUIFont(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
