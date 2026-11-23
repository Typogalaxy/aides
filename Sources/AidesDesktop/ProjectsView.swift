import AidesCore
import SwiftUI

struct ProjectsView: View {
    let workspace: Workspace
    @Binding var selection: UUID?
    let showConversation: (UUID) -> Void
    let showWorker: (UUID) -> Void

    @ViewState private var showsProject = false
    @ViewState private var conversationProject: Project?
    @ViewState private var proposalProject: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkRow {
                PageHeading("Projects", description: "Long-running work and its conversations.")
            } actions: {
                Button {
                    showsProject = true
                } label: {
                    Label("New project", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
            Divider()
            if workspace.state.projects.isEmpty {
                ContentUnavailableView("No projects", systemImage: "folder", description: Text("Create a project to keep related work together."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    if geometry.size.width >= 585 {
                        HStack(spacing: 0) {
                            List(workspace.state.projects, selection: $selection) { project in
                                Label(project.name, systemImage: "folder")
                                    .lineLimit(2)
                                    .help(project.name)
                                    .tag(project.id)
                            }
                            .listStyle(.sidebar)
                            .frame(width: 190)
                            Divider()
                            selectedProject
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            Menu {
                                ForEach(workspace.state.projects) { project in
                                    Button {
                                        selection = project.id
                                    } label: {
                                        if project.id == selection {
                                            Label(project.name, systemImage: "checkmark")
                                        } else {
                                            Text(project.name)
                                        }
                                    }
                                }
                            } label: {
                                Label("Choose project", systemImage: "folder")
                            }
                            .fixedSize()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            Divider()
                            selectedProject
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onChange(of: workspace.state.projects.map(\.id), initial: true) { _, ids in
            if let selection, ids.contains(selection) { return }
            selection = ids.first
        }
        .sheet(isPresented: $showsProject) {
            NewProjectSheet(workspace: workspace) { selection = $0 }
        }
        .sheet(item: $conversationProject) { project in
            NewConversationSheet(workspace: workspace, defaultProjectID: project.id, onCreated: showConversation)
        }
        .sheet(item: $proposalProject) { project in
            NewCodeProposalSheet(workspace: workspace, project: project, onCreated: showWorker)
        }
    }

    @ViewBuilder
    private var selectedProject: some View {
        if let project = workspace.state.projects.first(where: { $0.id == selection }) {
            details(project)
        } else {
            ContentUnavailableView("Select a project", systemImage: "folder")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func details(_ project: Project) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                PageHeading(project.name, description: "Created \(project.createdAt.formatted(date: .abbreviated, time: .omitted))")
                if let directory = project.directory {
                    WorkField(label: "Server directory", value: directory, monospaced: true)
                    WorkRow {
                        Toggle("Watch directory", isOn: Binding(
                            get: { project.watching == true },
                            set: { enabled in Task { await workspace.setProjectWatching(project.id, enabled: enabled) } }
                        ))
                        .disabled(workspace.isWorking)
                    } actions: {
                        Button("Propose code changes…") { proposalProject = project }
                            .disabled(workspace.state.models.isEmpty)
                    }
                }
                Divider()
                WorkRow {
                    Text("Project conversations").desktopUIFont(.headline)
                } actions: {
                    Button("New conversation") { conversationProject = project }
                }
                let threads = workspace.state.threads.filter { $0.projectID == project.id }
                if threads.isEmpty {
                    Text("No conversations yet.").foregroundStyle(.secondary)
                }
                ForEach(threads) { conversation in
                    Button {
                        showConversation(conversation.id)
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(conversation.title, systemImage: conversation.icon)
                                    .lineLimit(3)
                                if conversation.archivedAt != nil {
                                    Text("Archived").desktopUIFont(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .help(conversation.title)
                        .padding(11)
                        .background(.quaternary.opacity(0.27), in: .rect(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct NewProjectSheet: View {
    let workspace: Workspace
    let onCreated: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var directory = ""

    var body: some View {
        WorkFormSheet("New project") {
            TextField("Name", text: $name)
            TextField("Server directory (optional)", text: $directory)
            Text("Use an existing absolute path on the server Mac.")
                .desktopUIFont(.caption)
                .foregroundStyle(.secondary)
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Create") {
                Task {
                    if let id = await workspace.createProject(name.trimmed, directory: directory.trimmed.isEmpty ? nil : directory.trimmed) {
                        dismiss()
                        onCreated(id)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmed.isEmpty || workspace.isWorking)
        }
    }
}
