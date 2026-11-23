import SwiftUI

struct ToolkitSourcesView: View {
    let workspace: Workspace

    @ViewState private var sources: [ResourceSource] = []
    @ViewState private var deleting: ResourceSource?
    @ViewState private var showsAdd = false
    @ViewState private var busy = false
    @ViewState private var error: String?

    var body: some View {
        Form {
            Section("Web sources") {
                SettingsActions {
                    Button("Add source…") { showsAdd = true }
                        .disabled(sources.count >= 10)
                    Button("Refresh") { Task { await refresh() } }
                }
                if sources.isEmpty {
                    Text("Add an RSS feed or web page to receive a notice when it changes.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sources) { source in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(source.name).desktopUIFont(.body, weight: .medium)
                        SettingsActions {
                            Button(source.paused ? "Resume" : "Pause") {
                                Task { await pause(source) }
                            }
                            Button("Remove", role: .destructive) { deleting = source }
                        }
                        if let url = URL(string: source.url), url.scheme?.lowercased() == "https" {
                            Link("Open configured page", destination: url)
                        }
                        Text(source.url).desktopUIFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if source.paused {
                            Text("Paused").desktopUIFont(.caption).foregroundStyle(.secondary)
                        } else {
                            LabeledContent("Next check", value: source.nextCheckAt.formatted(date: .abbreviated, time: .shortened))
                                .desktopUIFont(.caption)
                        }
                        if let lastCheckedAt = source.lastCheckedAt {
                            LabeledContent("Last checked", value: lastCheckedAt.formatted(date: .abbreviated, time: .shortened))
                                .desktopUIFont(.caption)
                        }
                        if let error = source.lastError {
                            Text(error).desktopUIFont(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        if !source.entries.isEmpty {
                            DisclosureGroup("Recent entries") {
                                ForEach(source.entries) { entry in
                                    Text(entry.title)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
        .task { await refresh() }
        .sheet(isPresented: $showsAdd) {
            AddToolkitSourceSheet(workspace: workspace) { sources = $0 }
        }
        .confirmationDialog("Remove this source?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { source in
            Button("Remove", role: .destructive) { Task { await remove(source) } }
        } message: { source in
            Text(source.name)
        }
    }

    private func refresh() async {
        await update { try await workspace.toolkitGet(["sources"]) }
    }

    private func pause(_ source: ResourceSource) async {
        await update {
            try await workspace.toolkitPost(
                ["sources", source.id.uuidString, "pause"], body: SourcePauseRequest(paused: !source.paused)
            )
        }
    }

    private func remove(_ source: ResourceSource) async {
        await update { try await workspace.toolkitDelete(["sources", source.id.uuidString]) }
    }

    private func update(_ operation: () async throws -> SourcesResponse) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do { sources = try await operation().sources }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
}

private struct AddToolkitSourceSheet: View {
    let workspace: Workspace
    let onAdded: ([ResourceSource]) -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var url = ""
    @ViewState private var kind = SourceKind.feed
    @ViewState private var intervalMinutes = 30
    @ViewState private var busy = false
    @ViewState private var error: String?

    var body: some View {
        SettingsFormSheet(title: "Add source", idealWidth: 470) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsField("Name") {
                    TextField("", text: $name)
                }
                SettingsField("Public HTTPS URL") {
                    TextField("", text: $url)
                }
                Picker("Type", selection: $kind) {
                    Text("RSS or Atom").tag(SourceKind.feed)
                    Text("Web page").tag(SourceKind.page)
                }
                Stepper("Check every \(intervalMinutes) minutes", value: $intervalMinutes, in: 5...1440, step: 5)
            }
            .disabled(busy)
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            Button("Add source") { Task { await add() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || name.trimmed.isEmpty || URL(string: url.trimmed)?.scheme != "https")
        }
    }

    private func add() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let response: SourcesResponse = try await workspace.toolkitPost(
                ["sources"], body: NewSourceRequest(name: name.trimmed, url: url.trimmed, kind: kind, intervalMinutes: intervalMinutes)
            )
            onAdded(response.sources)
            dismiss()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private enum SourceKind: String, Codable, Sendable { case feed, page }

private struct SourceEntry: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
}

private struct ResourceSource: Decodable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let url: String
    let paused: Bool
    let nextCheckAt: Date
    let lastCheckedAt: Date?
    let lastError: String?
    let entries: [SourceEntry]
}

private struct SourcesResponse: Decodable, Sendable {
    let sources: [ResourceSource]
}

private struct NewSourceRequest: Encodable, Sendable {
    let name: String
    let url: String
    let kind: SourceKind
    let intervalMinutes: Int
}

private struct SourcePauseRequest: Encodable, Sendable {
    let paused: Bool
}
