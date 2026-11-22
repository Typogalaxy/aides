import AidesCore
import SwiftUI

struct ToolkitLocalView: View {
    let workspace: Workspace

    @ViewState private var actions: [ToolkitLocalAction] = []
    @ViewState private var actionID: String?
    @ViewState private var threadID: UUID?
    @ViewState private var projectID: UUID?
    @ViewState private var query = ""
    @ViewState private var path = ""
    @ViewState private var items: [ToolkitLocalItem]?
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var showsSchedule = false

    private var action: ToolkitLocalAction? { actions.first { $0.id == actionID } }

    var body: some View {
        Form {
            Section("Aides data tools") {
                Picker("Action", selection: $actionID) {
                    Text("Choose an action").tag(String?.none)
                    ForEach(actions) { action in
                        Text(action.title).tag(Optional(action.id))
                    }
                }
                if let action {
                    if action.requiresProject {
                        Picker("Project", selection: $projectID) {
                            Text("Choose a project").tag(UUID?.none)
                            ForEach(workspace.state.projects) { project in
                                Text(project.name).tag(Optional(project.id))
                            }
                        }
                    } else if action.id == "memory.search" {
                        Picker("Conversation scope", selection: $threadID) {
                            Text("Global").tag(UUID?.none)
                            ForEach(workspace.state.threads.filter { $0.role != .secretary }) { conversation in
                                Text(conversation.title).tag(Optional(conversation.id))
                            }
                        }
                    }
                    if action.acceptsQuery { TextField("Search terms", text: $query) }
                    if action.acceptsPath { TextField("Relative path", text: $path, prompt: Text(".")) }
                    Button("Run lookup") { Task { await lookup(action) } }
                        .disabled(action.requiresProject && projectID == nil)
                }
                if actions.isEmpty {
                    Button("Refresh actions") { Task { await loadActions() } }
                }
            }
            .disabled(busy)
            Section("Schedules") {
                Button("Create schedule…") { showsSchedule = true }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            if let items {
                Section("Results") {
                    if items.isEmpty { Text("No results.").foregroundStyle(.secondary) }
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.body.weight(.medium))
                            if let date = item.date {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let source = item.source, !source.isEmpty {
                                Text(source).font(.caption).foregroundStyle(.secondary)
                            }
                            if let detail = item.detail, !detail.isEmpty {
                                DisclosureGroup("Details") {
                                    ScrollView {
                                        Text(detail)
                                            .font(.system(.caption, design: .monospaced))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .frame(maxHeight: 200)
                                }
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await loadActions() }
        .onChange(of: actionID) { _, _ in items = nil }
        .sheet(isPresented: $showsSchedule) {
            NewScheduleSheet(workspace: workspace) {
                if action?.id == "schedules.list", let action {
                    Task { await lookup(action) }
                }
            }
        }
    }

    private func loadActions() async {
        await perform {
            let catalog: ToolkitLocalCatalog = try await workspace.toolkitGet(["local", "actions"])
            actions = catalog.actions
        }
    }

    private func lookup(_ action: ToolkitLocalAction) async {
        await perform {
            let request = ToolkitLocalRequest(
                action: action.id,
                threadID: action.id == "memory.search" ? threadID : nil,
                projectID: action.requiresProject ? projectID : nil,
                query: action.acceptsQuery && !query.trimmed.isEmpty ? query.trimmed : nil,
                path: action.acceptsPath && !path.trimmed.isEmpty ? path.trimmed : nil
            )
            let response: ToolkitLocalResponse = try await workspace.toolkitPost(["local", "query"], body: request)
            items = response.items
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do { try await operation() }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
}

struct ToolkitLocalAction: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let requiresProject: Bool
    let acceptsPath: Bool
    let acceptsQuery: Bool
}

struct ToolkitLocalCatalog: Decodable, Sendable {
    let actions: [ToolkitLocalAction]
}

private struct ToolkitLocalItem: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String?
    let source: String?
    let date: Date?
}

private struct ToolkitLocalResponse: Decodable, Sendable {
    let items: [ToolkitLocalItem]
}

private struct ToolkitLocalRequest: Encodable, Sendable {
    let action: String
    let threadID: UUID?
    let projectID: UUID?
    let query: String?
    let path: String?
}
