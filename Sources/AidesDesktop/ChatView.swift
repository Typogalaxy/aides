import AidesCore
import SwiftUI

struct ChatView: View {
    let workspace: Workspace
    let conversation: Conversation
    @Binding var draft: String
    let showWorker: (UUID) -> Void
    let showComputerUse: () -> Void

    private let conversationWidth: CGFloat = 736

    @ViewState private var showsTask = false
    @ViewState private var showsComputerUse = false
    @ViewState private var showsAppshot = false
    @ViewState private var proposalProject: Project?
    @ViewState private var showsReview = false
    @ViewState private var showsArchive = false
    @ViewState private var showsPreference = false
    @ViewState private var showsMemory = false
    @ViewState private var sourceMessage: Message?
    @ViewState private var toolkitResourceID: UUID?
    @ViewState private var toolkitMailAccountID: String?

    private var memoryScope: String {
        if let projectID = conversation.projectID { return "project:\(projectID.uuidString.lowercased())" }
        if conversation.role == .area { return "area:\(conversation.id.uuidString.lowercased())" }
        return "global"
    }

    private var tasks: [WorkItem] {
        workspace.state.tasks.filter { $0.threadID == conversation.id && $0.kind != .conversation }
    }

    private var desktopTasks: [ComputerRun] {
        workspace.computerRelay.runs.filter { $0.threadID == conversation.id && !$0.status.isTerminal }
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
                    if !tasks.isEmpty {
                        Menu("Conversation workers") {
                            ForEach(tasks.reversed()) { task in
                                Button(task.title) { showWorker(task.id) }
                            }
                        }
                    }
                    if !desktopTasks.isEmpty {
                        Button("View Computer Use runs") { showComputerUse() }
                    }
                    Button("Remember a note…") {
                        sourceMessage = nil
                        showsMemory = true
                    }
                    Button("Reply preferences…") { showsPreference = true }
                    if conversation.archivedAt == nil {
                        Button("Computer Use…") { showsComputerUse = true }
                            .disabled(workspace.computerRelay.isUnavailable)
                    }
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
        .onChange(of: conversation.id) { _, _ in
            toolkitResourceID = nil
            toolkitMailAccountID = nil
        }
        .sheet(isPresented: $showsTask) {
            NewTaskSheet(workspace: workspace, threadID: conversation.id, projectID: conversation.projectID) {
                showWorker($0)
            }
        }
        .sheet(isPresented: $showsAppshot) {
            if let appshot = workspace.appshots.draft {
                ComputerAppshotPreview(appshot: appshot)
            }
        }
        .sheet(isPresented: $showsComputerUse) {
            NewComputerUseSheet(workspace: workspace, instruction: draft, threadID: conversation.id)
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
                    LazyVStack(alignment: .leading, spacing: 44) {
                        ForEach(conversation.messages) { message in
                            VStack(alignment: .leading, spacing: 12) {
                                ChatMessageView(message: message)
                                if let suggestion = message.scheduleSuggestion {
                                    ScheduleSuggestionView(
                                        workspace: workspace, conversation: conversation,
                                        message: message, suggestion: suggestion
                                    )
                                }
                                if let suggestion = message.toolkitSuggestion {
                                    ToolkitSuggestionView(
                                        workspace: workspace, requestID: message.id, suggestion: suggestion,
                                        unavailable: conversation.archivedAt != nil
                                    )
                                }
                                if let suggestion = message.toolkitMailSuggestion {
                                    ToolkitMailSuggestionView(
                                        workspace: workspace, requestID: message.id, suggestion: suggestion,
                                        unavailable: conversation.archivedAt != nil
                                    )
                                }
                            }
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
                    .frame(maxWidth: conversationWidth)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 34)
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
            VStack(alignment: .trailing, spacing: 10) {
                if let appshot = workspace.appshots.draft {
                    HStack {
                        Button { showsAppshot = true } label: {
                            Label("Review current window", systemImage: "macwindow")
                        }
                        Text("Local model only").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") { workspace.appshots.remove(appshot.id) }
                    }
                }
                if let error = workspace.appshots.error {
                    Text(error).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                }
                TextField("Message \(conversation.title)…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...7)
                    .accessibilityLabel("Message")
                    .padding(.vertical, 4)
                    .padding(.horizontal, 3)
                HStack {
                    if workspace.appshots.draft == nil && !workspace.fileRelay.manifest.grants.isEmpty {
                        ToolkitFolderPicker(
                            workspace: workspace, selection: $toolkitResourceID, label: "Toolkit folder for this message"
                        )
                        .labelsHidden()
                        .fixedSize()
                        .disabled(workspace.isWorking)
                        .onChange(of: toolkitResourceID) { _, folder in
                            if folder != nil { toolkitMailAccountID = nil }
                        }
                    }
                    if workspace.appshots.draft == nil && workspace.state.settings.defaultModelID != nil {
                        ToolkitMailAccountPicker(
                            workspace: workspace, selection: $toolkitMailAccountID, label: "Mail draft…"
                        )
                        .disabled(workspace.isWorking)
                        .onChange(of: toolkitMailAccountID) { _, account in
                            if account != nil { toolkitResourceID = nil }
                        }
                    }
                    Spacer()
                    Button {
                        let original = draft
                        let message = original.trimmed
                        let appshot = workspace.appshots.draft
                        let mailAccount = appshot == nil ? toolkitMailAccountID : nil
                        let resource = appshot == nil && mailAccount == nil ? toolkitResourceID : nil
                        let conversationID = conversation.id
                        Task {
                            if await workspace.send(
                                message, in: conversationID, toolkitResourceID: resource, toolkitMailAccountID: mailAccount,
                                computerObservation: appshot?.observation
                            ) {
                                if let appshot { workspace.appshots.remove(appshot.id) }
                                if draft == original { draft = "" }
                                if toolkitResourceID == resource { toolkitResourceID = nil }
                                if toolkitMailAccountID == mailAccount { toolkitMailAccountID = nil }
                            }
                        }
                    } label: {
                        Label("Send", systemImage: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(workspace.isWorking || draft.trimmed.isEmpty)
                }
            }
            .padding(12)
            .background(.background, in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.separator, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: conversationWidth)
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ChatMessageView: View {
    let message: Message

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if message.isUser {
                HStack(alignment: .top, spacing: 0) {
                    Spacer(minLength: 38)
                    Text(message.text)
                        .font(.system(size: 16))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .foregroundStyle(colorScheme == .dark ? Color(red: 0.86, green: 0.96, blue: 0.89) : Color(red: 0.09, green: 0.22, blue: 0.15))
                        .background(
                            colorScheme == .dark ? Color(red: 0.13, green: 0.25, blue: 0.20) : Color(red: 0.85, green: 0.95, blue: 0.89),
                            in: .rect(cornerRadius: 20)
                        )
                        .frame(maxWidth: 514, alignment: .trailing)
                }
            } else {
                Text(message.text)
                    .font(.system(size: 16))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .help(message.createdAt.formatted(date: .abbreviated, time: .shortened))
    }
}

private struct ScheduleSuggestionView: View {
    let workspace: Workspace
    let conversation: Conversation
    let message: Message
    let suggestion: ScheduleSuggestion

    private var date: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: suggestion.timeZone)
        return formatter.string(from: suggestion.firstRun)
    }

    private var scheduled: Bool {
        workspace.state.schedules.contains {
            $0.threadID == conversation.id && $0.title == suggestion.title &&
                $0.firstRun == suggestion.firstRun && $0.timeZone == suggestion.timeZone &&
                $0.repeatRule == suggestion.repeatRule && $0.kind == suggestion.kind
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(suggestion.title, systemImage: "calendar.badge.clock")
                .font(.callout.weight(.medium))
            Text("\(suggestion.kind == .reminder ? "Reminder" : "Analysis") · \(suggestion.repeatRule.rawValue.capitalized)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(date) · \(suggestion.timeZone)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if scheduled {
                Label("Scheduled", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else if conversation.archivedAt == nil && suggestion.isValid(after: .now) {
                Button("Confirm schedule") {
                    Task { await workspace.confirmSchedule(suggestedBy: message.id) }
                }
                .disabled(workspace.isWorking)
            } else {
                Text("Schedule suggestion expired or archived.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
    }
}

struct ToolkitSuggestionView: View {
    let workspace: Workspace
    let requestID: UUID
    let suggestion: ToolkitSuggestion
    let unavailable: Bool

    @ViewState private var submitted: ToolkitInvocation?

    private var grant: DeviceFileGrant? {
        workspace.fileRelay.manifest.grants.first { $0.id == suggestion.resourceID }
    }

    private var job: DeviceFileJob? {
        workspace.fileRelay.manifest.jobs.first { $0.id == (submitted?.id ?? requestID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(suggestion.tool.descriptor.title, systemImage: "hammer")
                .font(.callout.weight(.medium))
            if let grant {
                LabeledContent("Folder", value: "\(grant.name) · \(workspace.toolkitDeviceName(grant.deviceID))")
            }
            LabeledContent("Path", value: suggestion.path.isEmpty ? "." : suggestion.path)
            if let destination = suggestion.destination {
                LabeledContent("Destination", value: destination)
            }
            if let status = job?.status ?? submitted?.status.rawValue {
                LabeledContent("Status", value: status.capitalized)
                if let result = job?.result ?? submitted?.result {
                    DisclosureGroup("Result") {
                        ScrollView {
                            Text(result)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                    }
                }
                if let error = job?.error ?? submitted?.error {
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else if !unavailable, grant != nil {
                if suggestion.tool.descriptor.approval == .targetDevice {
                    Text("The target Mac will ask before moving the file.")
                        .foregroundStyle(.secondary)
                }
                Button("Confirm file action") {
                    Task { submitted = await workspace.confirmToolkit(suggestedBy: requestID) }
                }
                .disabled(workspace.isWorking)
            } else {
                Text(unavailable ? "This proposal can no longer be confirmed." : "Folder access is unavailable.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
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
