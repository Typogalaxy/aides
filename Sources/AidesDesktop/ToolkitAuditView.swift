import AidesCore
import SwiftUI

struct ToolkitAuditView: View {
    let workspace: Workspace

    @ViewState private var entries: [ToolkitAuditEntry] = []
    @ViewState private var isLoading = false
    @ViewState private var error: String?

    var body: some View {
        Form {
            Section("Recent Toolkit requests") {
                Button("Refresh activity") { Task { await refresh() } }
                    .disabled(isLoading)
                if entries.isEmpty && !isLoading && error == nil {
                    Text("No Toolkit requests recorded.").foregroundStyle(.secondary)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(entry.action, value: "HTTP \(entry.status)")
                            .font(.callout.monospaced())
                        Text("\(workspace.toolkitDeviceName(entry.deviceID)) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let records: [ToolkitAuditEntry] = try await workspace.toolkitGet(["audit"])
            entries = records.sorted { $0.date > $1.date }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
