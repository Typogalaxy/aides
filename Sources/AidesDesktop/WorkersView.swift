import AidesCore
import SwiftUI

struct WorkersView: View {
    let workspace: Workspace
    let inspect: (UUID) -> Void

    @ViewState private var showsTask = false
    @ViewState private var showsReview = false
    @ViewState private var showsSchedule = false
    @ViewState private var filter = WorkerFilter.active

    private var shownTasks: [WorkItem] {
        workspace.state.tasks.reversed().filter { task in
            switch filter {
            case .active: !task.isFinished
            case .history: task.isFinished
            case .schedules: false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PageHeading("Workers", description: "Follow runs, review requests and manage scheduled work.")
                Button("New schedule") { showsSchedule = true }
                Button("Review task…") { showsReview = true }
                    .disabled(workspace.state.models.count < 2)
                Button {
                    showsTask = true
                } label: {
                    Label("Assign task", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
            Divider()
            Picker("Worker filter", selection: $filter) {
                ForEach(WorkerFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 305)
            .padding(15)
            if filter == .schedules {
                schedules
            } else if shownTasks.isEmpty {
                ContentUnavailableView(filter == .history ? "No completed runs" : "No active runs", systemImage: "gearshape.2")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shownTasks) { task in
                    Button {
                        inspect(task.id)
                    } label: {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(task.title).font(.body.weight(.medium)).lineLimit(2)
                                Text(task.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            TaskStatusView(task: task)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showsTask) {
            NewTaskSheet(workspace: workspace) { id in
                filter = .active
                inspect(id)
            }
        }
        .sheet(isPresented: $showsReview) {
            NewReviewSheet(workspace: workspace) { id in
                filter = .active
                inspect(id)
            }
        }
        .sheet(isPresented: $showsSchedule) {
            NewScheduleSheet(workspace: workspace) { filter = .schedules }
        }
    }

    @ViewBuilder
    private var schedules: some View {
        if workspace.state.schedules.isEmpty {
            ContentUnavailableView("No schedules", systemImage: "calendar")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(workspace.state.schedules) { schedule in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(schedule.title).font(.body.weight(.medium))
                        Text(scheduleDetail(schedule)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if schedule.paused || schedule.nextRun != nil {
                        Button(schedule.paused ? "Resume" : "Pause") {
                            Task { await workspace.setSchedulePaused(schedule.id, paused: !schedule.paused) }
                        }
                        .disabled(workspace.isWorking)
                    }
                }
                .padding(.vertical, 5)
            }
        }
    }

    private func scheduleDetail(_ schedule: AidesCore.WorkSchedule) -> String {
        let action = schedule.kind == .reminder ? "Reminder" : "Analysis"
        if schedule.paused { return "\(action) · \(schedule.repeatRule.rawValue.capitalized) · Paused" }
        if let date = schedule.nextRun {
            return "\(action) · \(schedule.repeatRule.rawValue.capitalized) · \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        return "\(action) · Complete"
    }
}

private enum WorkerFilter: String, CaseIterable {
    case active = "Active"
    case history = "History"
    case schedules = "Schedules"
}

struct TaskStatusView: View {
    let task: WorkItem
    var showsLabel = true

    private var statusColor: Color {
        switch task.status {
        case .completed: .green
        case .failed: .red
        case .waitingApproval, .waiting: .orange
        case .running: .aidesAccent
        default: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
                .accessibilityHidden(true)
            if showsLabel {
                Text(task.statusLabel)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(statusColor)
        .accessibilityLabel(task.statusLabel)
    }
}

struct WorkerInspector: View {
    let workspace: Workspace
    let task: WorkItem
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Worker").font(.headline)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close worker")
                .accessibilityLabel("Close worker")
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeading(task.title)
                    TaskStatusView(task: task)
                    if let model = workspace.state.models.first(where: { $0.id == task.modelID }) {
                        LabeledContent("Model", value: model.name)
                    }
                    if let scheduledAt = task.scheduledAt {
                        LabeledContent("Scheduled", value: scheduledAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Updated", value: task.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    if task.kind == .codeProposal {
                        CodeProposalDetails(workspace: workspace, task: task)
                            .id(task.id)
                    } else if task.kind == .review {
                        ReviewDetails(workspace: workspace, review: task)
                    } else if task.status == .waitingApproval {
                        ApprovalDetails(workspace: workspace, task: task)
                    }
                    if let message = task.error {
                        Label("Run details", systemImage: "exclamationmark.triangle").font(.headline)
                        Text(message).textSelection(.enabled)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let result = task.result, !result.isEmpty {
                        Text("Result").font(.headline)
                        Text(result)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    if let suggestion = task.toolkitSuggestion {
                        ToolkitSuggestionView(
                            workspace: workspace, requestID: task.id, suggestion: suggestion,
                            unavailable: task.status != .completed
                        )
                        .id(task.id)
                    }
                    if task.status == .waiting && task.kind != .review && task.kind != .retiredMail {
                        Button("Resume run") { Task { await workspace.resume(task.id) } }
                            .disabled(workspace.isWorking)
                    }
                    if !task.isFinished {
                        Button("Cancel run", role: .destructive) { Task { await workspace.cancel(task.id) } }
                            .disabled(workspace.isWorking)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.bar)
    }
}

struct NewTaskSheet: View {
    let workspace: Workspace
    var threadID: UUID? = nil
    var projectID: UUID? = nil
    let onCreated: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var title = ""
    @ViewState private var instruction = ""
    @ViewState private var modelID: UUID?
    @ViewState private var delayed = false
    @ViewState private var scheduledAt = Date.now.addingTimeInterval(3600)
    @ViewState private var sharedMemoryIDs: Set<UUID> = []
    @ViewState private var toolkitResourceID: UUID?
    @ViewState private var toolkitInvocationID: UUID?
    @ViewState private var localActions: [ToolkitLocalAction] = []
    @ViewState private var localActionID: String?
    @ViewState private var localProjectID: UUID?
    @ViewState private var localQuery = ""
    @ViewState private var localPath = ""

    private var model: ModelProfile? {
        workspace.state.models.first { $0.id == (modelID ?? workspace.state.settings.defaultModelID) }
    }

    private var usesCloud: Bool { model?.kind.isLocal == false }

    private var localReceipts: [DeviceFileJob] {
        let grants = Set(workspace.fileRelay.manifest.grants.map(\.id))
        return workspace.fileRelay.manifest.jobs.reversed().filter {
            $0.status == "completed" && ($0.operation == .read || $0.operation == .list) && $0.result != nil &&
                grants.contains($0.grantID) && (toolkitResourceID == nil || $0.grantID == toolkitResourceID)
        }
    }

    private var localAction: ToolkitLocalAction? { localActions.first { $0.id == localActionID } }

    private var taskProjectID: UUID? {
        projectID ?? workspace.state.threads.first(where: { $0.id == threadID })?.projectID ??
            (localAction == nil ? nil : localProjectID)
    }

    private var localInputIsValid: Bool {
        guard model?.kind.isLocal == true, let localAction else { return true }
        if localAction.requiresProject || localAction.id == "projects.list" {
            guard let taskProjectID, let project = workspace.state.projects.first(where: { $0.id == taskProjectID }),
                  !localAction.requiresProject || project.directory != nil else { return false }
        }
        return localAction.id != "projects.files.read" || !localPath.trimmed.isEmpty
    }

    private var localInputPicker: some View {
        Group {
            Picker("Aides data for local model", selection: $localActionID) {
                Text("No Aides data lookup").tag(String?.none)
                ForEach(localActions) { action in Text(action.title).tag(Optional(action.id)) }
            }
            .help("Run a scoped lookup when the local Worker starts and include the result in its input.")
            if let localAction {
                if projectID == nil && workspace.state.threads.first(where: { $0.id == threadID })?.projectID == nil {
                    Picker("Project scope", selection: $localProjectID) {
                        Text("Choose a project").tag(UUID?.none)
                        ForEach(workspace.state.projects) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                }
                if localAction.acceptsQuery {
                    TextField("Search terms (optional)", text: $localQuery)
                }
                if localAction.acceptsPath {
                    TextField("Relative path", text: $localPath)
                }
            }
        }
        .onChange(of: localActionID) { _, value in
            localPath = ""
            localQuery = ""
            if value != nil { toolkitInvocationID = nil }
        }
    }

    private var shareableMemories: [MemoryRecord] {
        let projectScope = projectID.map { "project:\($0.uuidString.lowercased())" }
        let areaScope = workspace.state.threads.first { $0.id == threadID && $0.role == .area }
            .map { "area:\($0.id.uuidString.lowercased())" }
        return workspace.memories.filter {
            $0.sensitivity == .cloudAllowed &&
                ($0.scope == "global" || $0.scope == projectScope || $0.scope == areaScope)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            PageHeading("Assign task")
            Form {
                TextField("Title", text: $title)
                TextField("Instructions", text: $instruction, axis: .vertical)
                    .lineLimit(3...6)
                ModelPicker(models: workspace.state.models, selection: $modelID)
                if model?.kind.isLocal == true {
                    if !workspace.fileRelay.manifest.grants.isEmpty {
                        ToolkitFolderPicker(
                            workspace: workspace, selection: $toolkitResourceID, label: "Toolkit folder for this run"
                        )
                    }
                    if !localReceipts.isEmpty {
                        Picker("File result for local model", selection: $toolkitInvocationID) {
                            Text("No file result").tag(UUID?.none)
                            ForEach(localReceipts) { receipt in
                                let path = receipt.path.isEmpty ? "." : receipt.path
                                Text("\(receipt.grantName) / \(path) · \(receipt.updatedAt.formatted(date: .omitted, time: .shortened))")
                                    .tag(Optional(receipt.id))
                            }
                        }
                        .disabled(localAction != nil)
                        .help("Include the selected completed file result in the local model's input for this run.")
                    }
                    if !localActions.isEmpty { localInputPicker }
                }
                if usesCloud && !shareableMemories.isEmpty {
                    Section("Memory to share (up to four)") {
                        ForEach(shareableMemories) { memory in
                            Toggle(memory.key, isOn: Binding(
                                get: { sharedMemoryIDs.contains(memory.id) },
                                set: { selected in
                                    if selected {
                                        sharedMemoryIDs.insert(memory.id)
                                    } else {
                                        sharedMemoryIDs.remove(memory.id)
                                    }
                                }
                            ))
                            .disabled(sharedMemoryIDs.count >= 4 && !sharedMemoryIDs.contains(memory.id))
                        }
                    }
                }
                Toggle("Start later", isOn: $delayed)
                if delayed { DatePicker("Start", selection: $scheduledAt, in: Date.now...) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(delayed ? "Schedule run" : "Assign") {
                    Task {
                        let request = TaskRequest(
                            title: title.trimmed, instruction: instruction.trimmed.isEmpty ? nil : instruction.trimmed,
                            threadID: threadID, projectID: model?.kind.isLocal == true ? taskProjectID : projectID,
                            modelID: modelID,
                            scheduledAt: delayed ? scheduledAt : nil,
                            sharedMemoryIDs: usesCloud ? shareableMemories.filter { sharedMemoryIDs.contains($0.id) }.map(\.id) : nil,
                            toolkitResourceID: model?.kind.isLocal == true ? toolkitResourceID : nil,
                            toolkitInvocationID: model?.kind.isLocal == true && localAction == nil
                                ? localReceipts.first { $0.id == toolkitInvocationID }?.id : nil,
                            toolkitLocalSelection: model?.kind.isLocal == true ? localAction.map { action in
                                ToolkitWorkerSelection(
                                    action: action.id,
                                    query: action.acceptsQuery && !localQuery.trimmed.isEmpty ? localQuery.trimmed : nil,
                                    path: action.acceptsPath && !localPath.trimmed.isEmpty ? localPath.trimmed : nil
                                )
                            } : nil
                        )
                        if let id = await workspace.createTask(request) {
                            dismiss()
                            onCreated(id)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmed.isEmpty || workspace.isWorking || !localInputIsValid)
            }
        }
        .padding(22)
        .frame(width: 490)
        .task {
            if let catalog: ToolkitLocalCatalog = try? await workspace.toolkitGet(["local", "actions"]) {
                localActions = catalog.actions
            }
        }
        .task(id: modelID) {
            sharedMemoryIDs = []
            if model?.kind.isLocal != true {
                toolkitResourceID = nil
                toolkitInvocationID = nil
                localActionID = nil
                localProjectID = nil
            }
            if usesCloud { await workspace.refreshMemories() }
        }
        .onChange(of: localReceipts.map(\.id)) { _, ids in
            if let toolkitInvocationID, !ids.contains(toolkitInvocationID) {
                self.toolkitInvocationID = nil
            }
        }
    }
}

struct NewScheduleSheet: View {
    let workspace: Workspace
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var title = ""
    @ViewState private var kind = "reminder"
    @ViewState private var repeatRule = "once"
    @ViewState private var timeZone = TimeZone.current.identifier
    @ViewState private var firstRun = Date.now.addingTimeInterval(3600)
    @ViewState private var threadID: UUID?
    @ViewState private var modelID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            PageHeading("New schedule")
            Form {
                TextField("Description", text: $title)
                Picker("Action", selection: $kind) {
                    Text("Reminder").tag("reminder")
                    Text("Analysis").tag("analysis")
                }
                Picker("Repeat", selection: $repeatRule) {
                    Text("Once").tag("once")
                    Text("Daily").tag("daily")
                    Text("Weekly").tag("weekly")
                }
                DatePicker("First run", selection: $firstRun, in: Date.now...)
                TextField("Repeat time zone", text: $timeZone, prompt: Text(TimeZone.current.identifier))
                Picker("Conversation", selection: $threadID) {
                    Text("Secretary").tag(UUID?.none)
                    ForEach(workspace.state.threads.filter { $0.role != .secretary && $0.archivedAt == nil }) { thread in
                        Text(thread.title).tag(Optional(thread.id))
                    }
                }
                if kind == "analysis" {
                    ModelPicker(models: workspace.state.models, selection: $modelID)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create schedule") {
                    Task {
                        let thread = workspace.state.threads.first { $0.id == threadID }
                        if await workspace.createSchedule(ScheduleRequest(
                            title: title.trimmed, threadID: threadID, projectID: thread?.projectID,
                            modelID: kind == "analysis" ? modelID : nil, kind: kind,
                            repeatRule: repeatRule, timeZone: timeZone.trimmed, firstRun: firstRun
                        )) {
                            dismiss()
                            onCreated()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmed.isEmpty || TimeZone(identifier: timeZone.trimmed) == nil || workspace.isWorking)
            }
        }
        .padding(22)
        .frame(width: 490)
    }
}

struct ModelPicker: View {
    let models: [ModelProfile]
    @Binding var selection: UUID?

    var body: some View {
        Picker("Model", selection: $selection) {
            Text("Server default").tag(UUID?.none)
            ForEach(models) { model in
                Text(model.name).tag(Optional(model.id))
            }
        }
    }
}
