import AidesCore
import SwiftUI

struct ToolkitGitHubView: View {
    let workspace: Workspace

    @ViewState private var repositories: [ToolkitGitHubRepository] = []
    @ViewState private var repositoryID: String?
    @ViewState private var kind = ToolkitGitHubItemKind.issues
    @ViewState private var items: [ToolkitGitHubItem]?
    @ViewState private var busy = false
    @ViewState private var error: String?

    var body: some View {
        Form {
            Section("GitHub repositories") {
                Button("Refresh repositories") { Task { await refresh() } }
                if repositories.isEmpty {
                    Text("Configure repositories on the Aides server to view issues, pull requests, or workflow runs.")
                        .foregroundStyle(.secondary)
                }
                if !repositories.isEmpty {
                    Picker("Repository", selection: $repositoryID) {
                        Text("Choose a repository").tag(String?.none)
                        ForEach(repositories) { repository in
                            Text("\(repository.label) · \(repository.owner)/\(repository.name)")
                                .tag(Optional(repository.id))
                        }
                    }
                    if let repository = repositories.first(where: { $0.id == repositoryID }) {
                        if repository.available {
                            Picker("Type", selection: $kind) {
                                ForEach(ToolkitGitHubItemKind.allCases, id: \.self) { kind in
                                    Text(kind.title).tag(kind)
                                }
                            }
                            Button("Load \(kind.title.lowercased())") { Task { await load(repository) } }
                        } else {
                            Text("The repository credential is unavailable.").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ToolkitGitHubWritesSection(
                workspace: workspace, repository: repositories.first { $0.id == repositoryID && $0.available }
            )
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
                        VStack(alignment: .leading, spacing: 5) {
                            SettingsDetail(item.title, value: item.state)
                            if let date = item.updatedAt {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .desktopUIFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let summary = item.summary, !summary.isEmpty {
                                Text(summary).lineLimit(3).foregroundStyle(.secondary)
                            }
                            if let url = githubURL(for: item) {
                                Link("Open on GitHub", destination: url)
                            }
                        }
                        .padding(.vertical, 4)
                        .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
        .task { await refresh() }
        .onChange(of: repositoryID) { _, _ in items = nil }
        .onChange(of: kind) { _, _ in items = nil }
    }

    private func githubURL(for item: ToolkitGitHubItem) -> URL? {
        let url = item.url
        guard url.scheme == "https",
              url.host?.lowercased() == "github.com", url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func refresh() async {
        await perform {
            repositories = try await workspace.toolkitGet(["github", "repositories"])
            if !repositories.contains(where: { $0.id == repositoryID }) {
                repositoryID = repositories.first(where: \.available)?.id
            }
        }
    }

    private func load(_ repository: ToolkitGitHubRepository) async {
        await perform {
            items = try await workspace.toolkitPost(
                ["github", "repositories", repository.id, "items"],
                body: ToolkitGitHubItemsRequest(kind: kind, limit: 15)
            )
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
