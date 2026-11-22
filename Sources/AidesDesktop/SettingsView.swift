import SwiftUI

struct SettingsView: View {
    let workspace: Workspace
    let updates: DesktopUpdates

    @ViewState private var pane = SettingsPane.models

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeading("Settings")
                .padding(20)
            Divider()
            Picker("Settings sections", selection: $pane) {
                ForEach(SettingsPane.allCases, id: \.self) { pane in Text(pane.rawValue).tag(pane) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)
            .padding(16)

            switch pane {
            case .models: ModelSettingsView(workspace: workspace)
            case .memory: MemorySettingsView(workspace: workspace)
            case .devices: DeviceSettingsView(workspace: workspace)
            case .application: ApplicationSettingsView(updates: updates)
            }
        }
    }
}

private enum SettingsPane: String, CaseIterable {
    case models = "Models"
    case memory = "Memory"
    case devices = "Devices"
    case application = "Application"
}

private struct ModelSettingsView: View {
    let workspace: Workspace

    @ViewState private var selection: UUID?
    @ViewState private var preference = ""
    @ViewState private var loadedPreference = ""
    @ViewState private var loadedModelID: UUID?
    @ViewState private var showsModel = false

    var body: some View {
        Form {
            Section("Defaults") {
                ModelPicker(models: workspace.state.models, selection: $selection)
                TextField("Global reply preference", text: $preference, axis: .vertical)
                    .lineLimit(3...6)
                Button("Save defaults") {
                    Task { await workspace.saveSettings(modelID: selection, preference: preference.trimmed) }
                }
                .disabled(workspace.isWorking || (preference == loadedPreference && selection == loadedModelID))
            }
            Section("Available models") {
                ForEach(workspace.state.models) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.name).font(.body.weight(.medium))
                            Text("\(model.kindLabel) · \(model.model)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.hasCredential {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Credential saved on server")
                        }
                    }
                    .padding(.vertical, 3)
                }
                Button("Add model…") { showsModel = true }
            }
        }
        .formStyle(.grouped)
        .onChange(of: workspace.state.settings.preference, initial: true) { _, value in
            if preference == loadedPreference { preference = value }
            loadedPreference = value
        }
        .onChange(of: workspace.state.settings.defaultModelID, initial: true) { _, value in
            if selection == loadedModelID { selection = value }
            loadedModelID = value
        }
        .sheet(isPresented: $showsModel) {
            AddModelSheet(workspace: workspace)
        }
    }
}

private struct AddModelSheet: View {
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    @ViewState private var name = ""
    @ViewState private var kind = ModelKind.ollama
    @ViewState private var endpoint = ModelKind.ollama.suggestedEndpoint
    @ViewState private var model = ""
    @ViewState private var key = ""

    private var providers: [ModelKind] {
        [.ollama, .openAI, .claude, .codex, .claudeCode, .mock]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            PageHeading("Add model")
            Form {
                TextField("Display name", text: $name)
                Picker("Provider", selection: $kind) {
                    ForEach(providers) { provider in Text(provider.label).tag(provider) }
                }
                if kind != .mock {
                    TextField(kind == .codex || kind == .claudeCode ? "Executable on server" : "Endpoint", text: $endpoint)
                }
                if kind == .codex || kind == .claudeCode {
                    TextField("Model identifier (optional)", text: $model)
                    Text("Sign in on the Mac running the server using the provider’s official command-line tool.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if kind != .mock {
                    TextField("Model identifier", text: $model)
                }
                if kind.usesAPIKey {
                    SecureField("API key", text: $key)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save model") {
                    Task {
                        let identifier = model.trimmed
                        let saved = await workspace.addModel(ModelRequest(
                            name: name.trimmed, kind: kind.rawValue, endpoint: endpoint.trimmed,
                            model: kind == .mock ? "mock" : identifier,
                            apiKey: kind.usesAPIKey && !key.trimmed.isEmpty ? key.trimmed : nil
                        ))
                        if saved {
                            key = ""
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(workspace.isWorking || name.trimmed.isEmpty || !providerIsConfigured)
            }
        }
        .padding(22)
        .frame(width: 510)
        .onChange(of: kind) { _, value in
            endpoint = value.suggestedEndpoint
            model = ""
            key = ""
        }
    }

    private var providerIsConfigured: Bool {
        switch kind {
        case .mock: true
        case .codex, .claudeCode: !endpoint.trimmed.isEmpty
        default: !endpoint.trimmed.isEmpty && !model.trimmed.isEmpty && (!kind.usesAPIKey || !key.trimmed.isEmpty)
        }
    }
}

private struct DeviceSettingsView: View {
    let workspace: Workspace
    @ViewState private var revoking: PairedDevice?

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Address", value: workspace.address).textSelection(.enabled)
                Button("Forget this connection") {
                    Task { await workspace.forgetConnection() }
                }
            }
            Section("Paired devices") {
                ForEach(workspace.state.devices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name).font(.body.weight(.medium))
                            Text(device.id == workspace.deviceID ? "This Mac" : device.createdAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke", role: .destructive) { revoking = device }
                    }
                    .padding(.vertical, 3)
                }
                Button("Create pairing code") { Task { await workspace.createInvite() } }
                if let code = workspace.newInvite {
                    LabeledContent("One-time code") {
                        Text(code).font(.body.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(workspace.isWorking)
        .confirmationDialog("Revoke this device?", isPresented: Binding(
            get: { revoking != nil },
            set: { if !$0 { revoking = nil } }
        ), presenting: revoking) { device in
            Button("Revoke \(device.name)", role: .destructive) {
                Task { await workspace.revokeDevice(device.id) }
            }
        } message: { device in
            Text("\(device.name) will need a new pairing code to reconnect.")
        }
    }
}

private struct MemorySettingsView: View {
    let workspace: Workspace

    @ViewState private var editor: MemoryEditorEntry?
    @ViewState private var deleting: MemoryRecord?

    var body: some View {
        Form {
            Section("Saved memory") {
                HStack {
                    Button("Add memory…") { editor = MemoryEditorEntry(record: nil) }
                    Button("Refresh") { Task { await workspace.refreshMemories() } }
                }
                if workspace.memories.isEmpty {
                    Text("No saved memory.").foregroundStyle(.secondary)
                }
                ForEach(workspace.memories) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(record.key).font(.body.weight(.medium))
                            Spacer()
                            Button("Edit") { editor = MemoryEditorEntry(record: record) }
                            Button("Delete", role: .destructive) { deleting = record }
                        }
                        Text(record.value).textSelection(.enabled)
                        Text("\(scopeName(record.scope)) · \(record.sensitivity == "localOnly" ? "Local only" : "Cloud eligible") · \(record.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .formStyle(.grouped)
        .task { await workspace.refreshMemories() }
        .disabled(workspace.isWorking)
        .sheet(item: $editor) { entry in
            MemoryEditor(workspace: workspace, existing: entry.record)
        }
        .confirmationDialog("Delete this memory?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { record in
            Button("Delete", role: .destructive) { Task { await workspace.deleteMemory(record.id) } }
        } message: { record in
            Text(record.key)
        }
    }

    private func scopeName(_ scope: String) -> String {
        if scope == "global" { return "Global" }
        let components = scope.split(separator: ":", maxSplits: 1)
        guard components.count == 2, let id = UUID(uuidString: String(components[1])) else { return scope }
        if components[0] == "project" {
            return workspace.state.projects.first { $0.id == id }?.name ?? "Project"
        }
        return workspace.state.threads.first { $0.id == id }?.title ?? "Area"
    }
}

private struct MemoryEditorEntry: Identifiable {
    let id = UUID()
    let record: MemoryRecord?
}

private struct MemoryEditor: View {
    let workspace: Workspace
    let existing: MemoryRecord?

    @Environment(\.dismiss) private var dismiss
    @ViewState private var key = ""
    @ViewState private var value = ""
    @ViewState private var scope = "global"
    @ViewState private var sensitivity = "localOnly"

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            PageHeading(existing == nil ? "Add memory" : "Edit memory")
            Form {
                TextField("Name", text: $key).disabled(existing != nil)
                TextField("Value", text: $value, axis: .vertical).lineLimit(3...7)
                Picker("Scope", selection: $scope) {
                    Text("Global").tag("global")
                    ForEach(workspace.state.projects) { project in
                        Text(project.name).tag("project:\(project.id.uuidString.lowercased())")
                    }
                    ForEach(workspace.state.threads.filter { $0.role == "area" }) { area in
                        Text(area.title).tag("area:\(area.id.uuidString.lowercased())")
                    }
                }
                .disabled(existing != nil)
                Picker("Sharing", selection: $sensitivity) {
                    Text("Local only").tag("localOnly")
                    Text("Eligible for approved cloud use").tag("cloudAllowed")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save memory") {
                    Task {
                        if await workspace.saveMemory(MemoryRequest(
                            key: key.trimmed, value: value.trimmed, scope: scope, sensitivity: sensitivity
                        )) { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmed.isEmpty || value.trimmed.isEmpty || workspace.isWorking)
            }
        }
        .padding(22)
        .frame(width: 470)
        .onAppear {
            if let existing {
                key = existing.key
                value = existing.value
                scope = existing.scope
                sensitivity = existing.sensitivity
            }
        }
    }
}

private struct ApplicationSettingsView: View {
    let updates: DesktopUpdates
    @AppStorage("aides.appearance") private var appearance = DesktopAppearance.system

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(DesktopAppearance.allCases) { appearance in
                        Text(appearance.rawValue.capitalized).tag(appearance)
                    }
                }
            }
            Section("Version") {
                LabeledContent("Aides", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                if updates.isAvailable {
                    Button("Check for updates…") { updates.check() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ActivityView: View {
    let state: DesktopState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading("Activity", description: "Usage recorded by the server.")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 177), spacing: 12)], spacing: 12) {
                    metric("Requests", value: state.metrics.requests.formatted(), icon: "arrow.left.arrow.right")
                    metric("Input tokens", value: state.metrics.inputTokens.formatted(), icon: "text.word.spacing")
                    metric("Output tokens", value: state.metrics.outputTokens.formatted(), icon: "text.alignleft")
                    metric("Storage", value: bytes(state.metrics.storageBytes), icon: "internaldrive")
                    metric("Network", value: bytes(state.metrics.networkBytes), icon: "network")
                    if let memory = state.metrics.memoryBytes {
                        metric("Server memory", value: bytes(memory), icon: "memorychip")
                    }
                }
                Divider()
                Text("Worker runs").font(.headline)
                LabeledContent("Active", value: state.tasks.filter { !$0.isFinished }.count.formatted())
                LabeledContent("Completed", value: state.tasks.filter { $0.status == "completed" }.count.formatted())
                LabeledContent("Failed", value: state.tasks.filter { $0.status == "failed" }.count.formatted())
            }
            .padding(24)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ name: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(name, systemImage: icon).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit().weight(.semibold))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 10))
    }

    private func bytes(_ amount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(amount), countStyle: .file)
    }
}
