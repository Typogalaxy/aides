import AidesCore
import SwiftUI

struct ChatView: View {
    let workspace: Workspace
    let conversation: Conversation
    @Binding var draft: String
    let showWorker: (UUID) -> Void

    @ViewState private var showsTask = false
    @ViewState private var proposalProject: Project?
    @ViewState private var showsReview = false
    @ViewState private var showsArchive = false
    @ViewState private var showsPreference = false
    @ViewState private var showsMemory = false
    @ViewState private var sourceMessage: Message?

    private var memoryScope: String {
        if let projectID = conversation.projectID { return "project:\(projectID.uuidString.lowercased())" }
        if conversation.role == .area { return "area:\(conversation.id.uuidString.lowercased())" }
        return "global"
    }

    private var tasks: [WorkItem] {
        workspace.state.tasks.filter { $0.threadID == conversation.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 15) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title).font(.headline)
                    Text(conversation.role.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if conversation.archivedAt == nil {
                    if let id = conversation.projectID,
                       let project = workspace.state.projects.first(where: { $0.id == id }), project.directory != nil {
                        Button("Propose code…") { proposalProject = project }
                            .disabled(workspace.state.models.isEmpty)
                    }
                    Button("Review task…") { showsReview = true }
                        .disabled(workspace.state.models.count < 2)
                    Button {
                        showsTask = true
                    } label: {
                        Label("Assign task", systemImage: "arrow.turn.down.right")
                    }
                    if conversation.role != .secretary {
                        Button {
                            showsArchive = true
                        } label: {
                            Image(systemName: "archivebox")
                        }
                        .help("Archive conversation")
                        .accessibilityLabel("Archive conversation")
                    }
                }
                Menu {
                    Button("Remember a note…") {
                        sourceMessage = nil
                        showsMemory = true
                    }
                    Button("Reply preferences…") { showsPreference = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .help("Conversation options")
                .accessibilityLabel("Conversation options")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            Divider()

            if !tasks.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(tasks.reversed()) { task in
                            Button {
                                showWorker(task.id)
                            } label: {
                                HStack(spacing: 6) {
                                    TaskStatusView(task: task, showsLabel: false)
                                    Text(task.title).lineLimit(1)
                                }
                                .font(.caption)
                                .padding(.horizontal, 3)
                            }
                            .help(task.statusLabel)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
                Divider()
            }

            timeline

            if let archivedAt = conversation.archivedAt {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Archived \(archivedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let report = conversation.report, !report.isEmpty {
                        Text(report).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            } else {
                composer
            }
        }
        .sheet(isPresented: $showsTask) {
            NewTaskSheet(workspace: workspace, threadID: conversation.id, projectID: conversation.projectID) {
                showWorker($0)
            }
        }
        .sheet(item: $proposalProject) { project in
            NewCodeProposalSheet(workspace: workspace, project: project, threadID: conversation.id, onCreated: showWorker)
        }
        .sheet(isPresented: $showsReview) {
            NewReviewSheet(workspace: workspace, threadID: conversation.id, projectID: conversation.projectID) {
                showWorker($0)
            }
        }
        .sheet(isPresented: $showsArchive) {
            ArchiveConversationSheet(workspace: workspace, conversation: conversation)
        }
        .sheet(isPresented: $showsMemory) {
            MemoryEditor(workspace: workspace, sourceMessage: sourceMessage, suggestedScope: memoryScope)
        }
        .sheet(isPresented: $showsPreference) {
            ReplyPreferenceSheet(workspace: workspace)
        }
    }

    private var timeline: some View {
        ScrollViewReader { scroll in
            ScrollView {
                if conversation.messages.isEmpty {
                    ContentUnavailableView(
                        "Start the conversation",
                        systemImage: conversation.icon,
                        description: Text("Send a message or assign a background task.")
                    )
                    .frame(minHeight: 180)
                } else {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(conversation.messages) { message in
                            ChatMessageView(message: message, conversationTitle: conversation.title)
                                .contextMenu {
                                    if message.isUser {
                                        Button("Remember this message…") {
                                            sourceMessage = message
                                            showsMemory = true
                                        }
                                    }
                                }
                        }
                        Color.clear.frame(height: 1).id("conversation-end")
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                }
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: conversation.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    scroll.scrollTo("conversation-end", anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .trailing, spacing: 8) {
                TextField("Message \(conversation.title)…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...7)
                    .accessibilityLabel("Message")
                    .padding(11)
                    .background(.quaternary.opacity(0.29), in: .rect(cornerRadius: 10))
                Button {
                    let original = draft
                    let message = original.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        if await workspace.send(message, in: conversation.id), draft == original {
                            draft = ""
                        }
                    }
                } label: {
                    Label("Send", systemImage: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(workspace.isWorking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(maxWidth: 760)
            .padding(15)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ChatMessageView: View {
    let message: Message
    let conversationTitle: String

    private var author: String {
        if message.isUser { return "You" }
        if message.role == .system { return "System" }
        return conversationTitle
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: message.isUser ? "person" : (message.role == .system ? "gearshape" : "sparkle"))
                .font(.callout.weight(.semibold))
                .foregroundStyle(message.isUser ? Color.secondary : Color.aidesAccent)
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.44), in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(author).font(.callout.weight(.semibold))
                    Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text(message.text)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct NewConversationSheet: View {
    let workspace: Workspace
    var defaultProjectID: UUID? = nil
    let onCreated: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var title = ""
    @ViewState private var role = "task"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading("New conversation")
            Form {
                TextField("Title", text: $title)
                if defaultProjectID == nil {
                    Picker("Role", selection: $role) {
                        Text("Task").tag("task")
                        Text("Area").tag("area")
                        Text("Project").tag("project")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task {
                        if let id = await workspace.createConversation(title.trimmed, role: role, projectID: defaultProjectID) {
                            dismiss()
                            onCreated(id)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmed.isEmpty || workspace.isWorking)
            }
        }
        .padding(22)
        .frame(width: 415)
        .onAppear { if defaultProjectID != nil { role = "project" } }
    }
}

private struct ArchiveConversationSheet: View {
    let workspace: Workspace
    let conversation: Conversation

    @Environment(\.dismiss) private var dismiss
    @ViewState private var report = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading("Archive conversation", description: "Record the outcome and any work still outstanding.")
            TextField("Short report", text: $report, axis: .vertical)
                .lineLimit(3...7)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Archive") {
                    Task {
                        if await workspace.archive(conversation.id, report: report.trimmed) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(report.trimmed.isEmpty || workspace.isWorking)
            }
        }
        .padding(22)
        .frame(width: 455)
    }
}

private struct ReplyPreferenceSheet: View {
    let workspace: Workspace

    @Environment(\.dismiss) private var dismiss
    @ViewState private var preference = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading("Reply preferences", description: "Apply to future replies in every conversation.")
            TextField("Global reply preference", text: $preference, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
            if let error = workspace.error {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        if await workspace.saveReplyPreference(preference.trimmed) { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(workspace.isWorking || preference == workspace.state.settings.preference)
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear { preference = workspace.state.settings.preference }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
