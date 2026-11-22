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
    @ViewState private var conversationID: UUID?
    @ViewState private var projectID: UUID?
    @ViewState private var inspectorTaskID: UUID?
    @ViewState private var drafts: [UUID: String] = [:]
    @ViewState private var showsNewConversation = false

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
            sidebar
            Divider()
            VStack(spacing: 0) {
                if let message = workspace.connectionError {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.slash")
                        Text(message)
                    }
                    .font(.callout)
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
    }

    private var inspectorTask: WorkItem? {
        workspace.state.tasks.first { $0.id == inspectorTaskID }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(width: 31, height: 31)
                    .background(Color.aidesAccent, in: .rect(cornerRadius: 9))
                Text("Aides")
                    .font(.title2.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 15)

            ForEach(WorkspacePage.allCases) { destination in
                Button {
                    page = destination
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: destination.icon)
                            .frame(width: 16)
                            .foregroundStyle(page == destination ? Color.aidesAccent : Color.secondary)
                        Text(destination.title)
                            .font(.callout.weight(page == destination ? .semibold : .regular))
                        Spacer()
                        if destination == .workers {
                            let approvals = workspace.state.tasks.count { $0.status == .waitingApproval }
                            if approvals > 0 {
                                Text(approvals.formatted())
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(page == destination ? Color.aidesAccent.opacity(0.14) : .clear,
                                in: .rect(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == destination ? .isSelected : [])
            }

            Spacer()

            if workspace.fileRelay.pendingMove != nil {
                Button("Review file move") {
                    page = .settings
                    settingsPane = .files
                }
                .buttonStyle(.bordered)
            }

            if updates.hasUpdate {
                Button(action: updates.check) {
                    Label("Update available", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .buttonStyle(.bordered)
                .tint(.aidesAccent)
            }

            HStack(spacing: 7) {
                Circle()
                    .fill(workspace.connectionError == nil ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(workspace.connectionError == nil ? "Server connected" : "Reconnecting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(9)
        }
        .padding(10)
        .frame(width: 175)
        .background(.bar)
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
            SettingsView(workspace: workspace, updates: updates, pane: $settingsPane)
        }
    }

    @ViewBuilder
    private var conversationsView: some View {
        HStack(spacing: 0) {
            conversationList
                .frame(width: 210)
            Divider()
            if let current = workspace.state.threads.first(where: { $0.id == conversationID }) {
                ChatView(
                    workspace: workspace,
                    conversation: current,
                    draft: Binding(
                        get: { drafts[current.id, default: ""] },
                        set: { drafts[current.id] = $0 }
                    ),
                    showWorker: { inspectorTaskID = $0 }
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
    }

    private var conversationList: some View {
        let active = workspace.state.threads.filter { $0.archivedAt == nil }
        let archived = workspace.state.threads.filter { $0.archivedAt != nil }
        return VStack(spacing: 0) {
            HStack {
                Text("Conversations").font(.headline)
                Spacer()
                Button {
                    showsNewConversation = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("New conversation")
                .accessibilityLabel("New conversation")
            }
            .padding(14)
            Divider()
            List(selection: $conversationID) {
                if !active.isEmpty {
                    Section("Active") {
                        ForEach(active) { row($0) }
                    }
                }
                if !archived.isEmpty {
                    Section("Archived") {
                        ForEach(archived) { row($0) }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(.quaternary.opacity(0.22))
    }

    private func row(_ conversation: Conversation) -> some View {
        Label(conversation.title, systemImage: conversation.icon)
            .lineLimit(1)
            .tag(conversation.id)
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
                Text("Connect to Aides").font(.largeTitle.weight(.semibold))
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
                .font(.callout)
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
            Text(title).font(.title2.weight(.semibold))
            if let description {
                Text(description).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
