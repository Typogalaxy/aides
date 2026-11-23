import AidesCore
import SwiftUI

struct ToolkitCommandsView: View {
    let workspace: Workspace

    @ViewState private var commands: [ToolkitCommand] = []
    @ViewState private var runs: [ToolkitCommandRun] = []
    @ViewState private var confirming: ToolkitCommand?
    @ViewState private var pending: [String: UUID] = [:]
    @ViewState private var busy = false
    @ViewState private var error: String?

    var body: some View {
        Form {
            Section("Host commands") {
                Button("Refresh commands and runs") { Task { await refresh() } }
                if commands.isEmpty {
                    Text("Configure project commands on the Aides server to make them available here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(commands, id: \.id) { command in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(command.label).desktopUIFont(.body, weight: .medium)
                            Text(projectName(command)).desktopUIFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Review run…") { confirming = command }
                    }
                }
            }
            Section("Recent runs") {
                if runs.isEmpty { Text("No recorded command runs.").foregroundStyle(.secondary) }
                ForEach(runs, id: \.id) { run in
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsDetail(
                            commands.first { $0.id == run.commandID }?.label ?? run.commandID,
                            value: run.status.rawValue.capitalized
                        )
                        if let exitCode = run.exitCode {
                            LabeledContent("Exit code", value: String(exitCode))
                        }
                        if let message = run.message {
                            Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let output = run.output, !output.isEmpty {
                            DisclosureGroup("Output") {
                                ScrollView {
                                    Text(output)
                                        .desktopCodeFont()
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 240)
                            }
                        }
                        if run.status.isActive {
                            Button(run.stopRequested == true ? "Stop requested" : "Cancel run", role: .destructive) {
                                Task { await cancel(run) }
                            }
                            .disabled(run.stopRequested == true)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
        .task { await refresh() }
        .task(id: runs.contains { $0.status.isActive }) {
            guard runs.contains(where: { $0.status.isActive }) else { return }
            while !Task.isCancelled && runs.contains(where: { $0.status.isActive }) {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
        .confirmationDialog("Run this command?", isPresented: Binding(
            get: { confirming != nil },
            set: { if !$0 { confirming = nil } }
        ), presenting: confirming) { command in
            Button("Confirm and run") { Task { await run(command) } }
        } message: { command in
            let arguments = (try? JSONEncoder().encode(command.arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            Text("\(command.label) · \(projectName(command))\n\(command.executable)\nArguments: \(arguments)\nTimeout: \(command.timeoutSeconds) seconds")
        }
    }

    private func projectName(_ command: ToolkitCommand) -> String {
        workspace.state.projects.first { $0.id == command.projectID }?.name ?? "Project on server"
    }

    private func refresh() async {
        await perform {
            async let catalog: [ToolkitCommand] = workspace.toolkitGet(["commands"])
            async let receipts: [ToolkitCommandRun] = workspace.toolkitGet(["commands", "runs"])
            (commands, runs) = try await (catalog, receipts)
        }
    }

    private func run(_ command: ToolkitCommand) async {
        await perform {
            let id = pending[command.revision] ?? UUID()
            pending[command.revision] = id
            let receipt: ToolkitCommandRun = try await workspace.toolkitPost(
                ["commands", command.id, "run"], body: StartToolkitCommand(id: id, approved: true, revision: command.revision)
            )
            update(receipt)
            pending.removeValue(forKey: command.revision)
        }
    }

    private func cancel(_ run: ToolkitCommandRun) async {
        await perform {
            let receipt: ToolkitCommandRun = try await workspace.toolkitPost(
                ["commands", "runs", run.id.uuidString, "cancel"], body: CancelToolkitCommand()
            )
            update(receipt)
        }
    }

    private func update(_ run: ToolkitCommandRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.insert(run, at: 0)
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

private struct StartToolkitCommand: Encodable, Sendable {
    let id: UUID
    let approved: Bool
    let revision: String
}

private struct CancelToolkitCommand: Encodable, Sendable {}
