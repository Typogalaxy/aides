import AidesCore
import SwiftUI

struct ToolkitMailWatchesSection: View {
    let workspace: Workspace
    let account: ToolkitMailAccount?
    let query: String

    @ViewState private var watches: [ToolkitMailWatchStatus] = []
    @ViewState private var refreshError: String?
    @ViewState private var isWorking = false
    @ViewState private var showsAdd = false
    @ViewState private var removing: ToolkitMailWatchStatus?

    var body: some View {
        Section("Mail watches") {
            SettingsActions {
                Button("Add mail watch…") { showsAdd = true }.disabled(account == nil)
                Button("Refresh") { Task { await refresh() } }
            }
            if watches.isEmpty {
                Text("Aides can check an approved account and search for new matches in the background.")
                    .foregroundStyle(.secondary)
            }
            ForEach(watches) { watch in
                VStack(alignment: .leading, spacing: 5) {
                    Text(watch.query).desktopUIFont(.body, weight: .medium)
                    SettingsActions {
                        Button(watch.paused ? "Resume" : "Pause") { Task { await toggle(watch) } }
                        Button("Remove", role: .destructive) { removing = watch }
                    }
                    let interval = "\(watch.intervalMinutes) min"
                    Text("\(watch.accountLabel) · \(watch.paused ? "Paused" : interval)")
                        .desktopUIFont(.caption)
                        .foregroundStyle(.secondary)
                    if let checked = watch.lastCheckedAt {
                        LabeledContent("Latest check", value: checked.formatted(date: .abbreviated, time: .shortened))
                            .desktopUIFont(.caption)
                        Text("\(watch.matchingCount) recent matches").desktopUIFont(.caption).foregroundStyle(.secondary)
                    }
                    if let error = watch.lastError {
                        Text(error).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 3)
            }
            if let refreshError {
                Label(refreshError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .disabled(isWorking)
        .task { await refresh() }
        .sheet(isPresented: $showsAdd) {
            if let account {
                AddToolkitMailWatchSheet(workspace: workspace, account: account, initialQuery: query) { watches = $0 }
            }
        }
        .confirmationDialog("Remove this watch?", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), presenting: removing) { watch in
            Button("Remove", role: .destructive) { Task { await remove(watch) } }
        } message: { watch in
            Text("\(watch.accountLabel) · \(watch.query)")
        }
    }

    private func refresh() async {
        await update { try await workspace.toolkitGet(["mail", "watches"]) }
    }

    private func toggle(_ watch: ToolkitMailWatchStatus) async {
        await update {
            try await workspace.toolkitPost(
                ["mail", "watches", watch.id.uuidString, "pause"], body: MailWatchPauseRequest(paused: !watch.paused)
            )
        }
    }

    private func remove(_ watch: ToolkitMailWatchStatus) async {
        await update { try await workspace.toolkitDelete(["mail", "watches", watch.id.uuidString]) }
    }

    private func update(_ operation: () async throws -> ToolkitMailWatchList) async {
        guard !isWorking else { return }
        isWorking = true
        refreshError = nil
        defer { isWorking = false }
        do { watches = try await operation().watches }
        catch is CancellationError {}
        catch { refreshError = error.localizedDescription }
    }
}

private struct AddToolkitMailWatchSheet: View {
    let workspace: Workspace
    let account: ToolkitMailAccount
    let initialQuery: String
    let onAdded: ([ToolkitMailWatchStatus]) -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var query = ""
    @ViewState private var intervalMinutes = 30
    @ViewState private var isWorking = false
    @ViewState private var error: String?

    var body: some View {
        SettingsFormSheet(title: "Add mail watch", idealWidth: 460) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsDetail("Account", value: account.address)
                SettingsField("Search terms") {
                    TextField("", text: $query)
                }
                Stepper("Check every \(intervalMinutes) minutes", value: $intervalMinutes, in: 5...1440, step: 5)
                Text("The first check establishes the baseline. Later matches create a notice in Aides.")
                    .desktopUIFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Confirm and start watch") { Task { await add() } }
                .buttonStyle(.borderedProminent)
                .disabled(query.trimmed.isEmpty)
        }
        .disabled(isWorking)
        .onAppear { query = initialQuery }
    }

    private func add() async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let result: ToolkitMailWatchList = try await workspace.toolkitPost(
                ["mail", "watches"],
                body: ToolkitMailWatchRequest(accountID: account.id, query: query.trimmed, intervalMinutes: intervalMinutes)
            )
            onAdded(result.watches)
            dismiss()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct MailWatchPauseRequest: Encodable, Sendable {
    let paused: Bool
}
