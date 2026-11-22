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
                Section("File change requested on this Mac") { pendingMove(request) }
            }
            if let error = relay.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            Section("File and folder access") {
                HStack {
                    Button("Share local folder…") { chooseFolder() }
                    Button("Refresh") { Task { await relay.refresh() } }
                }
                ForEach(relay.manifest.grants) { grant in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(grant.name).desktopUIFont(.body, weight: .medium)
                            Text("\(deviceName(grant.deviceID)) · \(accessLabel(grant))")
                                .desktopUIFont(.caption)
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
                        .desktopUIFont(.callout)
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
                            Text(request.operation.title).desktopUIFont(.body, weight: .medium)
                            Spacer()
                            Text(request.status.capitalized).desktopUIFont(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(deviceName(request.deviceID)) · \(request.grantName) / \(request.path)")
                            .desktopUIFont(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let destination = request.destination {
                            Text("To \(destination)").desktopUIFont(.caption).textSelection(.enabled)
                        }
                        if let result = request.result {
                            DisclosureGroup("Result") {
                                ScrollView {
                                    Text(result)
                                        .desktopUIFont(.caption, design: .monospaced)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 240)
                            }
                        }
                        if let error = request.error {
                            Text(error).desktopUIFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 3)
                }
                Text("Aides must be open on the target Mac to handle these requests.")
                    .desktopUIFont(.caption)
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

    private func accessLabel(_ grant: DeviceFileGrant) -> String {
        var labels = ["Read"]
        if grant.allowMoves { labels.append("move") }
        if grant.allowWrites == true { labels.append("write") }
        return labels.joined(separator: " · ")
    }

    private func reviewText(_ label: String, _ text: String) -> some View {
        DisclosureGroup(label) {
            ScrollView {
                Text(text.isEmpty ? "(Empty)" : text)
                    .monospaced().textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        }
    }

    private func pendingMove(_ request: DeviceFileJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Folder", value: request.grantName)
            LabeledContent("Path", value: request.path)
            if let destination = request.destination { LabeledContent("Destination", value: destination) }
            if let expected = request.expectedText { reviewText("Expected text", expected) }
            if let text = request.text { reviewText("New text", text) }
            HStack {
                Button("Decline") { Task { await relay.respondToMove(request.id, approved: false) } }
                Button(request.operation.title) { Task { await relay.respondToMove(request.id, approved: true) } }
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
    @ViewState private var allowWrites = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading("Share a local folder")
            Text(folder.path).desktopUIFont(.caption, design: .monospaced).textSelection(.enabled)
            Form {
                TextField("Name on other Macs", text: $name)
                Toggle("Allow move requests", isOn: $allowMoves)
                Toggle("Allow text write requests", isOn: $allowWrites)
            }
            Text("Paired devices can list the directory or request text files. File changes require approval on this Mac. The folder’s local path stays on this Mac.")
                .desktopUIFont(.caption)
                .foregroundStyle(.secondary)
            if let error = relay.error {
                Text(error).desktopUIFont(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Share folder") {
                    Task {
                        if await relay.grantAccess(
                            to: folder, displayName: name.trimmed, allowMoves: allowMoves, allowWrites: allowWrites
                        ) { dismiss() }
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
    @ViewState private var text = ""
    @ViewState private var expectedText = ""
    @ViewState private var lastSubmission: (request: FileJobRequest, id: UUID)?

    private var operations: [FileOperation] {
        var actions: [FileOperation] = [.list, .read]
        if grant.allowMoves { actions.append(.move) }
        if grant.allowWrites == true { actions += [.create, .replace] }
        return actions
    }

    private var isValid: Bool {
        (operation == .list || !path.trimmed.isEmpty) &&
            (operation != .move || (!destination.trimmed.isEmpty && path.trimmed != destination.trimmed)) &&
            (!operation.writesText || (text.utf8.count <= 4_096 && expectedText.utf8.count <= 4_096))
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
                if operation == .replace {
                    TextField("Expected text", text: $expectedText, axis: .vertical).lineLimit(2...5)
                }
                if operation.writesText {
                    TextField("New text", text: $text, axis: .vertical).lineLimit(2...5)
                }
            }
            if let error = relay.error {
                Text(error).desktopUIFont(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send request") {
                    let request = FileJobRequest(
                        grantID: grant.id, operation: operation, path: path.trimmed,
                        destination: operation == .move ? destination.trimmed : nil,
                        text: operation.writesText ? text : nil,
                        expectedText: operation == .replace ? expectedText : nil
                    )
                    let invocationID = lastSubmission.flatMap { $0.request == request ? $0.id : nil } ?? UUID()
                    lastSubmission = (request, invocationID)
                    Task {
                        if await relay.submit(request, invocationID: invocationID) { dismiss() }
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
