import AidesCore
import SwiftUI

struct ToolkitGitHubWritesSection: View {
    let workspace: Workspace
    let repository: ToolkitGitHubRepository?

    @ViewState private var requests: [ToolkitGitHubWrite] = []
    @ViewState private var reviewing: ToolkitGitHubWrite?
    @ViewState private var showsCreate = false
    @ViewState private var busy = false
    @ViewState private var error: String?

    var body: some View {
        Section("Issue and pull request approvals") {
            SettingsActions {
                if repository?.allowedWrites?.isEmpty == false {
                    Button("Prepare request…") { showsCreate = true }
                }
                Button("Refresh requests") { Task { await refresh() } }
            }
            .disabled(busy)
            if requests.isEmpty {
                Text("No issue or pull request approvals are recorded. Enable writes for a repository on the Aides server to prepare a request.")
                    .foregroundStyle(.secondary)
            }
            ForEach(requests) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.request.title).desktopUIFont(.body, weight: .medium)
                        Text("\(entry.repositoryOwner)/\(entry.repositoryName) · \(entry.request.kind.title)")
                            .desktopUIFont(.caption).foregroundStyle(.secondary)
                        Text(entry.status.title)
                            .desktopUIFont(.caption)
                            .foregroundStyle(entry.status == .interrupted ? .orange : .secondary)
                    }
                    Spacer()
                    Button(entry.status == .awaitingConfirmation ? "Review…" : "Details…") { reviewing = entry }
                }
                .padding(.vertical, 3)
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        }
        .task { await refresh() }
        .sheet(isPresented: $showsCreate) {
            if let repository {
                AddToolkitGitHubWriteSheet(workspace: workspace, repository: repository, onUpdated: update)
            }
        }
        .sheet(item: $reviewing) { entry in
            ToolkitGitHubWriteReviewSheet(workspace: workspace, entry: entry, onUpdated: update)
        }
    }

    private func refresh() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do { requests = try await workspace.toolkitGet(["github", "writes"]) }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }

    private func update(_ item: ToolkitGitHubWrite) {
        if let index = requests.firstIndex(where: { $0.id == item.id }) {
            requests[index] = item
        } else {
            requests.insert(item, at: 0)
        }
    }
}

private struct AddToolkitGitHubWriteSheet: View {
    let workspace: Workspace
    let repository: ToolkitGitHubRepository
    let onUpdated: (ToolkitGitHubWrite) -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var kind = ToolkitGitHubWriteKind.issue
    @ViewState private var title = ""
    @ViewState private var text = ""
    @ViewState private var head = ""
    @ViewState private var base = ""
    @ViewState private var lastRequest: ToolkitGitHubWriteRequest?
    @ViewState private var busy = false
    @ViewState private var error: String?

    var body: some View {
        SettingsFormSheet(title: "Prepare GitHub request", idealWidth: 530) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsDetail("Repository", value: "\(repository.owner)/\(repository.name)")
                Picker("Create", selection: $kind) {
                    ForEach(repository.allowedWrites ?? [], id: \.self) { entry in
                        Text(entry.title).tag(entry)
                    }
                }
                SettingsField("Title") {
                    TextField("", text: $title)
                }
                SettingsField("Description") {
                    TextField("", text: $text, axis: .vertical).lineLimit(5...12)
                }
                if kind == .pullRequest {
                    SettingsField("Head branch") {
                        TextField("", text: $head)
                    }
                    SettingsField("Base branch") {
                        TextField("", text: $base)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save for review") { Task { await prepare() } }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmed.isEmpty || (kind == .pullRequest && (head.trimmed.isEmpty || base.trimmed.isEmpty)))
        }
        .disabled(busy)
        .onAppear {
            if let first = repository.allowedWrites?.first { kind = first }
        }
    }

    private func prepare() async {
        guard !busy else { return }
        let headBranch = kind == .pullRequest ? head.trimmed : nil
        let baseBranch = kind == .pullRequest ? base.trimmed : nil
        let value: ToolkitGitHubWriteRequest
        if let lastRequest, lastRequest.kind == kind, lastRequest.title == title.trimmed, lastRequest.body == text,
           lastRequest.head == headBranch, lastRequest.base == baseBranch {
            value = lastRequest
        } else {
            value = ToolkitGitHubWriteRequest(
                id: UUID(), repositoryID: repository.id, kind: kind, title: title.trimmed, body: text,
                head: headBranch, base: baseBranch
            )
        }
        lastRequest = value
        busy = true
        error = nil
        defer { busy = false }
        do {
            let result: ToolkitGitHubWrite = try await workspace.toolkitPost(["github", "writes"], body: value)
            onUpdated(result)
            dismiss()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ToolkitGitHubWriteReviewSheet: View {
    let workspace: Workspace
    @ViewState var entry: ToolkitGitHubWrite
    let onUpdated: (ToolkitGitHubWrite) -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var busy = false
    @ViewState private var error: String?

    var body: some View {
        SettingsFormSheet(title: entry.request.kind.title, idealWidth: 540) {
            SettingsDetail("Repository", value: "\(entry.repositoryOwner)/\(entry.repositoryName)")
            SettingsDetail("Title", value: entry.request.title)
            if let head = entry.request.head, let base = entry.request.base {
                SettingsDetail("Merge", value: "\(head) → \(base)")
            }
            SettingsDetail("Status", value: entry.status.title)
            if let url = entry.url, url.scheme == "https", url.host == "github.com" {
                Link("Open on GitHub", destination: url)
            }
            Text(entry.request.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let error = error ?? entry.error { Text(error).foregroundStyle(.orange) }
        } actions: {
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            if entry.status == .awaitingConfirmation && entry.requestedByDeviceID == workspace.deviceID {
                Button("Decline", role: .destructive) { Task { await decide(approved: false) } }
                Button("Confirm and submit") { Task { await decide(approved: true) } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .disabled(busy)
        .textSelection(.enabled)
    }

    private func decide(approved: Bool) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let changed: ToolkitGitHubWrite = try await workspace.toolkitPost(
                ["github", "writes", entry.id.uuidString, "decision"], body: ToolkitMailDecision(approved: approved)
            )
            entry = changed
            onUpdated(changed)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
            if let list: [ToolkitGitHubWrite] = try? await workspace.toolkitGet(["github", "writes"]),
               let changed = list.first(where: { $0.id == entry.id }) {
                entry = changed
                onUpdated(changed)
            }
        }
    }
}

private extension ToolkitGitHubWriteStatus {
    var title: String {
        switch self {
        case .awaitingConfirmation: "Awaiting confirmation"
        case .submitting: "Submitting"
        case .submitted: "Submitted to GitHub"
        case .declined: "Declined"
        case .interrupted: "Outcome unknown"
        }
    }
}
