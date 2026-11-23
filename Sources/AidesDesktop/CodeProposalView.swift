import AidesCore
import SwiftUI

struct NewCodeProposalSheet: View {
    let workspace: Workspace
    let project: Project
    var threadID: UUID?
    let onCreated: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var title = ""
    @ViewState private var instruction = ""
    @ViewState private var paths = ""
    @ViewState private var selection: UUID?

    private var filePaths: [String] {
        paths.split(whereSeparator: \.isNewline).map { String($0).trimmed }.filter { !$0.isEmpty }
    }

    private var validPaths: Bool {
        !filePaths.isEmpty && Set(filePaths).count == filePaths.count && filePaths.allSatisfy { path in
            !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
        }
    }

    var body: some View {
        WorkFormSheet("Propose code changes", description: "Select the exact files the model can see. Review each proposed change before applying it.") {
            WorkField(label: "Project", value: project.name)
            TextField("Title", text: $title)
            TextField("Instructions", text: $instruction, axis: .vertical).lineLimit(3...6)
            TextField("Relative paths, one per line", text: $paths, axis: .vertical).lineLimit(3...6)
            Picker("Model", selection: $selection) {
                Text("Choose a model").tag(UUID?.none)
                ForEach(workspace.state.models) { model in
                    Text(model.name).tag(Optional(model.id))
                }
            }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Create proposal") {
                guard let selection else { return }
                Task {
                    let request = CodeProposalRequest(
                        title: title.trimmed, instruction: instruction.trimmed, modelID: selection,
                        projectID: project.id, threadID: threadID, paths: filePaths
                    )
                    if let id = await workspace.createCodeProposal(request) {
                        dismiss()
                        onCreated(id)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(title.trimmed.isEmpty || instruction.trimmed.isEmpty || !validPaths || selection == nil || workspace.isWorking)
        }
    }
}

struct CodeProposalDetails: View {
    let workspace: Workspace
    let task: WorkItem

    @ViewState private var details: CodeProposalDetail?
    @ViewState private var loadError: String?
    @ViewState private var selection: String?
    @ViewState private var pathToApply: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            if let details {
                if task.status == .waitingApproval {
                    Text("Review the listed files before sending them to the provider.")
                        .desktopUIFont(.callout)
                        .foregroundStyle(.secondary)
                    sources(details.files)
                    ApprovalDetails(workspace: workspace, task: task, includesFiles: true)
                } else if !details.changes.isEmpty {
                    changes(details)
                } else if let summary = details.summary {
                    summaryText(summary)
                } else {
                    sources(details.files)
                }
            } else if let loadError {
                Text(loadError)
                    .desktopUIFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { Task { await load() } }
            } else {
                ProgressView("Loading files…").controlSize(.small)
            }
        }
        .task(id: task.updatedAt) { await load() }
        .confirmationDialog("Apply this file?", isPresented: Binding(
            get: { pathToApply != nil },
            set: { if !$0 { pathToApply = nil } }
        ), presenting: pathToApply) { path in
            Button("Apply file") {
                Task {
                    if await workspace.applyCodeProposal(task.id, path: path) { await load() }
                }
            }
        } message: { path in
            Text(path)
        }
    }

    private func sources(_ files: [CodeProposalFile]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files in proposal").desktopUIFont(.headline)
            ForEach(files) { file in
                DisclosureGroup {
                    if let contents = file.contents {
                        code(contents)
                    } else {
                        Text("New file").desktopUIFont(.caption).foregroundStyle(.secondary)
                    }
                } label: {
                    Text(file.path)
                        .desktopUIFont(.caption, design: .monospaced)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func changes(_ details: CodeProposalDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Proposed changes").desktopUIFont(.headline)
            if let summary = details.summary {
                summaryText(summary)
            }
            Menu {
                ForEach(details.changes) { change in
                    let suffix = details.appliedPaths.contains(change.path) ? " · Applied" : ""
                    Button {
                        selection = change.path
                    } label: {
                        if change.path == selection {
                            Label(change.path + suffix, systemImage: "checkmark")
                        } else {
                            Text(change.path + suffix)
                        }
                    }
                }
            } label: {
                Label("Choose file", systemImage: "doc.text")
            }
            .fixedSize()
            if let change = details.changes.first(where: { $0.path == selection }) {
                WorkField(label: "Path", value: change.path, monospaced: true)
                if let previous = change.originalContents {
                    DisclosureGroup("Original text") { code(previous) }
                } else {
                    Text("New file").desktopUIFont(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Proposed text", isExpanded: .constant(true)) { code(change.proposedContents) }
                if details.appliedPaths.contains(change.path) {
                    Label("Applied", systemImage: "checkmark.circle")
                        .desktopUIFont(.callout)
                        .foregroundStyle(.green)
                } else {
                    Button("Apply this file…") { pathToApply = change.path }
                        .buttonStyle(.borderedProminent)
                        .disabled(workspace.isWorking)
                }
            }
        }
    }

    private func summaryText(_ text: String) -> some View {
        Text(text)
            .desktopUIFont(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func code(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text.isEmpty ? "(Empty file)" : text)
                .desktopCodeFont()
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(8)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 85, idealHeight: 160, maxHeight: 230)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 7))
    }

    private func load() async {
        do {
            let next = try await workspace.codeProposal(task.id)
            guard !Task.isCancelled else { return }
            details = next
            loadError = nil
            if !next.changes.contains(where: { $0.path == selection }) {
                selection = next.changes.first?.path
            }
        } catch {
            guard !Task.isCancelled else { return }
            details = nil
            loadError = error.localizedDescription
        }
    }
}

struct CodeProposalRequest: Encodable, Sendable {
    let title: String
    let instruction: String
    let modelID: UUID
    let projectID: UUID
    let threadID: UUID?
    let paths: [String]
}

struct CodeProposalDetail: Decodable, Sendable {
    let files: [CodeProposalFile]
    let changes: [CodeProposalChange]
    let appliedPaths: [String]
    let summary: String?
}

struct CodeProposalFile: Decodable, Identifiable, Sendable {
    let path: String
    let contents: String?
    var id: String { path }
}

struct CodeProposalChange: Decodable, Identifiable, Sendable {
    let path: String
    let originalContents: String?
    let proposedContents: String
    var id: String { path }
}
