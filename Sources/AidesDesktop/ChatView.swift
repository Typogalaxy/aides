import AidesCore
import SwiftUI

struct ChatView: View {
    let workspace: Workspace
    let conversation: Conversation
    @Binding var draft: String
    @Binding var draftAttachments: [ChatFileAttachment]
    let showWorker: (UUID) -> Void
    let showComputerUse: () -> Void

    @Environment(\.desktopTypography) private var typography

    private let conversationWidth: CGFloat = 736

    @ViewState private var showsFilesMenu = false
    @ViewState private var isPickingFiles = false
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
    @ViewState private var followsLatestReply = true
    @ViewState private var isScrollingManually = false

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
            ViewThatFits(in: .horizontal) {
                conversationHeader(compact: false)
                conversationHeader(compact: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            Divider()

            timeline

            if let archivedAt = conversation.archivedAt {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Archived \(archivedAt.formatted(date: .abbreviated, time: .omitted))")
                        .desktopUIFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                    if let report = conversation.report, !report.isEmpty {
                        ScrollView {
                            Text(report)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 110)
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

    private func conversationHeader(compact: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title)
                    .desktopUIFont(.headline)
                    .lineLimit(1)
                    .help(conversation.title)
                Text(conversation.role.rawValue.capitalized)
                    .desktopUIFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if !compact { conversationActions(inMenu: false) }
            Menu {
                if compact, conversation.archivedAt == nil {
                    conversationActions(inMenu: true)
                    Divider()
                }
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
    }

    @ViewBuilder
    private func conversationActions(inMenu: Bool) -> some View {
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
                    if inMenu {
                        Label("Archive conversation", systemImage: "archivebox")
                    } else {
                        Image(systemName: "archivebox")
                    }
                }
                .help("Archive conversation")
                .accessibilityLabel("Archive conversation")
            }
        }
    }

    private var timeline: some View {
        let preview = workspace.replyPreview(for: conversation.id)
        let hasPreview = preview.map { draft in
            conversation.messages.contains { $0.id == draft.originMessageID } &&
                !conversation.messages.contains { $0.id == draft.id }
        } ?? false
        let isWaiting = preview == nil && workspace.state.tasks.contains {
            $0.threadID == conversation.id && $0.kind == .conversation && [.queued, .running].contains($0.status)
        }
        var messages = conversation.messages
        if hasPreview, let preview {
            messages.append(Message(preview.text, role: .assistant, id: preview.id))
        }

        return ScrollViewReader { scroll in
            ScrollView {
                if messages.isEmpty {
                    ContentUnavailableView(
                        "Start the conversation",
                        systemImage: conversation.icon,
                        description: Text("Send a message or assign a background task.")
                    )
                    .frame(minHeight: 180)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 44) {
                            ForEach(messages) { message in
                                messageRow(message, isPreview: hasPreview && message.id == preview?.id)
                            }
                            if isWaiting {
                                ThinkingIndicator()
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
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                Self.isNearEnd(geometry)
            } action: { _, nearEnd in
                if isScrollingManually { followsLatestReply = nearEnd }
            }
            .onScrollPhaseChange { _, phase, context in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    isScrollingManually = true
                case .idle:
                    if isScrollingManually { followsLatestReply = Self.isNearEnd(context.geometry) }
                    isScrollingManually = false
                default:
                    break
                }
            }
            .onChange(of: messages.last?.text) { _, _ in
                if followsLatestReply, !isScrollingManually {
                    scroll.scrollTo("conversation-end", anchor: .bottom)
                }
            }
        }
    }

    private static func isNearEnd(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentSize.height - geometry.visibleRect.maxY < 44
    }

    private func messageRow(_ message: Message, isPreview: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ChatMessageView(message: message, isPreview: isPreview)
            if let suggestion = message.scheduleSuggestion {
                ScheduleSuggestionView(
                    workspace: workspace, conversation: conversation, message: message, suggestion: suggestion
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

    private var composer: some View {
        VStack(spacing: 0) {
            VStack(alignment: .trailing, spacing: 10) {
                if let appshot = workspace.appshots.draft {
                    HStack {
                        Button { showsAppshot = true } label: {
                            Label("Review current window", systemImage: "macwindow")
                        }
                        Text("Local model only").desktopUIFont(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") { workspace.appshots.remove(appshot.id) }
                    }
                }
                if let error = workspace.appshots.error {
                    Text(error).desktopUIFont(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !draftAttachments.isEmpty {
                    draftAttachmentList
                    if workspace.appshots.draft != nil {
                        Text("Remove the window attachment or the selected files before sending.")
                            .desktopUIFont(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                let prompt = "Message \(conversation.title)…"
                ChatComposerInput(text: $draft, placeholder: prompt, fontSize: typography.contentSize, send: sendDraft)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 3)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        attachmentMenu
                        composerSelections
                        Spacer(minLength: 8)
                        sendButton
                    }
                    HStack {
                        attachmentMenu
                        if showsComposerSelections {
                            Menu {
                                composerSelections
                            } label: {
                                Label("Message options", systemImage: "slider.horizontal.3")
                                    .labelStyle(.iconOnly)
                            }
                            .help("Message options")
                            .accessibilityLabel("Message options")
                        }
                        Spacer(minLength: 8)
                        sendButton
                    }
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

    private var showsComposerSelections: Bool {
        workspace.appshots.draft == nil &&
            (!workspace.fileRelay.manifest.grants.isEmpty ||
                (conversation.role != .secretary && workspace.state.settings.defaultModelID != nil))
    }

    @ViewBuilder
    private var composerSelections: some View {
        if workspace.appshots.draft == nil, !workspace.fileRelay.manifest.grants.isEmpty {
            ToolkitFolderPicker(
                workspace: workspace, selection: $toolkitResourceID, label: "Toolkit folder for this message"
            )
            .labelsHidden()
            .fixedSize()
            .disabled(workspace.isWorking || !draftAttachments.isEmpty)
            .onChange(of: toolkitResourceID) { _, folder in
                if folder != nil { toolkitMailAccountID = nil }
            }
        }
        if conversation.role != .secretary, workspace.appshots.draft == nil,
           workspace.state.settings.defaultModelID != nil {
            ToolkitMailAccountPicker(
                workspace: workspace, selection: $toolkitMailAccountID, label: "Mail draft…"
            )
            .disabled(workspace.isWorking || !draftAttachments.isEmpty)
            .onChange(of: toolkitMailAccountID) { _, account in
                if account != nil { toolkitResourceID = nil }
            }
        }
    }

    private var sendButton: some View {
        Button(action: sendDraft) {
            Label("Send", systemImage: "arrow.up")
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canSendDraft)
    }

    private var attachmentMenu: some View {
        Button { showsFilesMenu.toggle() } label: {
            Image(systemName: "plus")
                .desktopUIFont(.headline, weight: .medium)
                .frame(width: 30, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Add files and folders")
        .accessibilityLabel("Add files and folders")
        .disabled(workspace.isWorking || isPickingFiles)
        .popover(isPresented: $showsFilesMenu, arrowEdge: .bottom) {
            Button {
                showsFilesMenu = false
                Task { await pickFiles() }
            } label: {
                Label("Files and Folders", systemImage: "paperclip")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(10)
            .frame(minWidth: 180)
            .disabled(!canPickFiles)
            .help(canPickFiles ? "Choose local files or folders" :
                "Select a local Ollama model and clear any window, Toolkit folder, or mail selection.")
        }
    }

    private var canPickFiles: Bool {
        workspace.appshots.draft == nil && toolkitResourceID == nil && toolkitMailAccountID == nil &&
            workspace.state.models.contains { $0.id == workspace.state.settings.defaultModelID && $0.kind == .ollama }
    }

    private var draftAttachmentList: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draftAttachments) { attachment in
                    HStack(spacing: 6) {
                        Label(attachment.name, systemImage: attachment.kind == .folder ? "folder" : "doc")
                            .lineLimit(1)
                        Button {
                            draftAttachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(attachment.name)")
                        .accessibilityLabel("Remove \(attachment.name)")
                        .disabled(workspace.isWorking || isPickingFiles)
                    }
                    .desktopUIFont(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func pickFiles() async {
        guard canPickFiles, !isPickingFiles else { return }
        isPickingFiles = true
        defer { isPickingFiles = false }
        do {
            if let selected = try await ChatFilePicker.select(keeping: draftAttachments) {
                draftAttachments = selected
            }
        } catch {
            workspace.error = error.localizedDescription
        }
    }

    private var canSendDraft: Bool {
        !workspace.isWorking && !isPickingFiles && !draft.trimmed.isEmpty &&
            (draftAttachments.isEmpty || canPickFiles)
    }

    private func sendDraft() {
        guard canSendDraft else { return }
        let original = draft
        let message = original.trimmed
        let attachments = draftAttachments
        let appshot = workspace.appshots.draft
        let mailAccount = appshot == nil ? toolkitMailAccountID : nil
        let resource = appshot == nil && mailAccount == nil ? toolkitResourceID : nil
        let conversationID = conversation.id
        Task {
            if await workspace.send(
                message, in: conversationID, toolkitResourceID: resource, toolkitMailAccountID: mailAccount,
                computerObservation: appshot?.observation, attachments: attachments
            ) {
                if let appshot { workspace.appshots.remove(appshot.id) }
                if draft == original { draft = "" }
                if draftAttachments.map(\.id) == attachments.map(\.id) { draftAttachments = [] }
                if toolkitResourceID == resource { toolkitResourceID = nil }
                if toolkitMailAccountID == mailAccount { toolkitMailAccountID = nil }
            }
        }
    }
}

private struct ThinkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if reduceMotion {
                Text("Thinking").foregroundStyle(.secondary)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let sweep = timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.8) / 1.8
                    let center = sweep * 1.7 - 0.35
                    let gray = Color(white: colorScheme == .dark ? 0.62 : 0.47)
                    Text("Thinking")
                        .foregroundStyle(
                            LinearGradient(
                                colors: [gray, Color(white: 0.95), gray],
                                startPoint: UnitPoint(x: center - 0.32, y: 0.5),
                                endPoint: UnitPoint(x: center + 0.32, y: 0.5)
                            )
                        )
                }
            }
        }
        .desktopUIFont(.callout, weight: .medium)
    }
}

private struct ChatMessageView: View {
    let message: Message
    let isPreview: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.desktopTypography) private var typography

    var body: some View {
        Group {
            if message.isUser {
                HStack(alignment: .top, spacing: 0) {
                    Spacer(minLength: 38)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message.text)
                            .font(.system(size: typography.contentSize))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                        if let attachments = message.attachments {
                            ForEach(attachments) { attachment in
                                Label(attachment.name, systemImage: attachment.kind == .folder ? "folder" : "doc")
                                    .desktopUIFont(.caption)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11 + 1 / displayScale)
                    .foregroundStyle(colorScheme == .dark ? Color(red: 0.86, green: 0.96, blue: 0.89) : Color(red: 0.09, green: 0.22, blue: 0.15))
                    .background(
                        colorScheme == .dark ? Color(red: 0.13, green: 0.25, blue: 0.20) : Color(red: 0.85, green: 0.95, blue: 0.89),
                        in: .rect(cornerRadius: 20)
                    )
                    .frame(maxWidth: 514, alignment: .trailing)
                }
            } else if message.role == .assistant {
                ChatMarkdownView(source: message.text, bodySize: typography.contentSize, codeSize: typography.codeSize)
            } else {
                Text(message.text)
                    .desktopUIFont(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .help(isPreview ? "Receiving a reply" : message.createdAt.formatted(date: .abbreviated, time: .shortened))
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
                .desktopUIFont(.callout, weight: .medium)
            Text("\(suggestion.kind == .reminder ? "Reminder" : "Analysis") · \(suggestion.repeatRule.rawValue.capitalized)")
                .desktopUIFont(.caption)
                .foregroundStyle(.secondary)
            Text("\(date) · \(suggestion.timeZone)")
                .desktopUIFont(.caption)
                .foregroundStyle(.secondary)
            if scheduled {
                Label("Scheduled", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .desktopUIFont(.callout)
            } else if conversation.archivedAt == nil && suggestion.isValid(after: .now) {
                Button("Confirm schedule") {
                    Task { await workspace.confirmSchedule(suggestedBy: message.id) }
                }
                .disabled(workspace.isWorking)
            } else {
                Text("Schedule suggestion expired or archived.")
                    .desktopUIFont(.caption)
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
                .desktopUIFont(.callout, weight: .medium)
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
                                .desktopCodeFont()
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
        .desktopUIFont(.callout)
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Title").desktopUIFont(.callout, weight: .medium)
                TextField("Title", text: $title)
                    .labelsHidden()
                    .accessibilityLabel("Title")
                    .textFieldStyle(.roundedBorder)
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
                Text(error).desktopUIFont(.callout).foregroundStyle(.orange)
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
