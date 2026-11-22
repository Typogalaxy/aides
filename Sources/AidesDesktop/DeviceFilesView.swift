import AppKit
import SwiftUI

struct DeviceFilesView: View {
    let workspace: Workspace

    @ViewState private var pickedFolder: DirectorySelection?
    @ViewState private var selectedGrant: DeviceFileGrant?
    @ViewState private var revoking: DeviceFileGrant?

    private var relay: DeviceFileRelay { workspace.fileRelay }

    var body: some View {
        Form {
            if let request = relay.pendingMove {
                Section("Move requested on this Mac") { pendingMove(request) }
            }
            if let error = relay.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            Section("Shared folders") {
                HStack {
                    Button("Share local folder…") { chooseFolder() }
                    Button("Refresh") { Task { await relay.refresh() } }
                }
                ForEach(relay.manifest.grants) { grant in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(grant.name).font(.body.weight(.medium))
                            Text("\(deviceName(grant.deviceID)) · \(grant.allowMoves ? "Read and move" : "Read only")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("File action…") { selectedGrant = grant }
                        if grant.deviceID == workspace.deviceID {
                            Button("Revoke", role: .destructive) { revoking = grant }
                        }
                    }
                    .padding(.vertical, 3)
                }
                if relay.manifest.grants.isEmpty {
                    Text("Share a specific folder to request file operations from paired Macs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section("File requests") {
                if relay.manifest.jobs.isEmpty {
                    Text("No requests yet.").foregroundStyle(.secondary)
                }
                ForEach(relay.manifest.jobs.reversed()) { request in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(request.operation.title).font(.body.weight(.medium))
                            Spacer()
                            Text(request.status.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(deviceName(request.deviceID)) · \(request.grantName) / \(request.path)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let destination = request.destination {
                            Text("To \(destination)").font(.caption).textSelection(.enabled)
                        }
                        if let result = request.result {
                            DisclosureGroup("Result") {
                                ScrollView {
                                    Text(result)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 240)
                            }
                        }
                        if let error = request.error {
                            Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 3)
                }
                Text("Aides must be open on the target Mac to handle these requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await relay.refresh() }
        .sheet(item: $pickedFolder) { picked in
            ShareFolderSheet(relay: relay, folder: picked.url)
        }
        .sheet(item: $selectedGrant) { grant in
            FileJobSheet(relay: relay, grant: grant)
        }
        .confirmationDialog("Revoke folder access?", isPresented: Binding(
            get: { revoking != nil },
            set: { if !$0 { revoking = nil } }
        ), presenting: revoking) { grant in
            Button("Revoke", role: .destructive) { Task { await relay.revoke(grant) } }
        } message: { grant in
            Text(grant.name)
        }
    }

    private func deviceName(_ id: UUID) -> String {
        if id == workspace.deviceID { return "This Mac" }
        return workspace.state.devices.first { $0.id == id }?.name ?? "Paired Mac"
    }

    private func pendingMove(_ request: DeviceFileJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Folder", value: request.grantName)
            LabeledContent("Source", value: request.path)
            LabeledContent("Destination", value: request.destination ?? "")
            HStack {
                Button("Decline") { Task { await relay.respondToMove(request.id, approved: false) } }
                Button("Move file") { Task { await relay.respondToMove(request.id, approved: true) } }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(relay.isWorking)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose folder"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                pickedFolder = DirectorySelection(url: url)
            }
        }
    }
}

private struct DirectorySelection: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ShareFolderSheet: View {
    let relay: DeviceFileRelay
    let folder: URL
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var allowMoves = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading("Share a local folder")
            Text(folder.path).font(.caption.monospaced()).textSelection(.enabled)
            Form {
                TextField("Name on other Macs", text: $name)
                Toggle("Allow move requests", isOn: $allowMoves)
            }
            Text("Paired devices can list the directory or request text files. File moves require approval on this Mac. The folder’s local path stays on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = relay.error {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Share folder") {
                    Task {
                        if await relay.grantAccess(to: folder, displayName: name.trimmed, allowMoves: allowMoves) { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmed.isEmpty || relay.isWorking)
            }
        }
        .padding(22)
        .frame(width: 485)
        .onAppear { name = folder.lastPathComponent }
    }
}

private struct FileJobSheet: View {
    let relay: DeviceFileRelay
    let grant: DeviceFileGrant
    @Environment(\.dismiss) private var dismiss
    @ViewState private var operation = FileOperation.list
    @ViewState private var path = ""
    @ViewState private var destination = ""

    private var operations: [FileOperation] {
        grant.allowMoves ? FileOperation.allCases : [.list, .read]
    }

    private var isValid: Bool {
        (operation == .list || !path.trimmed.isEmpty) &&
            (operation != .move || (!destination.trimmed.isEmpty && path.trimmed != destination.trimmed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading("Request a file action")
            Form {
                LabeledContent("Shared folder", value: grant.name)
                Picker("Action", selection: $operation) {
                    ForEach(operations) { action in Text(action.title).tag(action) }
                }
                TextField(operation == .list ? "Relative path (optional)" : "Relative path", text: $path)
                if operation == .move {
                    TextField("Destination relative path", text: $destination)
                }
            }
            if let error = relay.error {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send request") {
                    Task {
                        if await relay.submit(FileJobRequest(
                            grantID: grant.id, operation: operation, path: path.trimmed,
                            destination: operation == .move ? destination.trimmed : nil
                        )) { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || relay.isWorking)
            }
        }
        .padding(22)
        .frame(width: 455)
    }
}
