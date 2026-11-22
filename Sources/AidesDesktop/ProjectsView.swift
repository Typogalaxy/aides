import AidesCore
import SwiftUI

struct ProjectsView: View {
    let workspace: Workspace
    @Binding var selection: UUID?
    let showConversation: (UUID) -> Void

    @ViewState private var showsProject = false
    @ViewState private var conversationProject: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PageHeading("Projects", description: "Long-running work and its conversations.")
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
                HStack(spacing: 0) {
                    List(workspace.state.projects, selection: $selection) { project in
                        Label(project.name, systemImage: "folder").tag(project.id)
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 170, idealWidth: 200, maxWidth: 235)
                    Divider()
                    if let project = workspace.state.projects.first(where: { $0.id == selection }) {
                        details(project)
                    } else {
                        ContentUnavailableView("Select a project", systemImage: "folder")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
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
    }

    private func details(_ project: Project) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                PageHeading(project.name, description: "Created \(project.createdAt.formatted(date: .abbreviated, time: .omitted))")
                if let directory = project.directory {
                    Label(directory, systemImage: "externaldrive")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Divider()
                HStack {
                    Text("Project conversations").font(.headline)
                    Spacer()
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
                        HStack {
                            Label(conversation.title, systemImage: conversation.icon)
                            Spacer()
                            if conversation.archivedAt != nil {
                                Text("Archived").font(.caption).foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
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
        VStack(alignment: .leading, spacing: 16) {
            PageHeading("New project")
            Form {
                TextField("Name", text: $name)
                TextField("Server directory (optional)", text: $directory)
            }
            Text("Use an existing absolute path on the server Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
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
        .padding(22)
        .frame(width: 465)
    }
}
