import SwiftUI

enum ToolkitPane: String, CaseIterable {
    case files = "Files"
    case mail = "Mail"
    case local = "Aides data"
    case sources = "Web sources"
    case commands = "Commands"
    case native = "Calendar & contacts"
    case notifications = "Notifications"
    case computer = "Computer Use"
    case github = "GitHub"
    case audit = "Audit"
}

struct ToolkitSettingsView: View {
    let workspace: Workspace
    @Binding var pane: ToolkitPane

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Toolkit category", selection: $pane) {
                ForEach(ToolkitPane.allCases, id: \.self) { category in
                    Text(category.rawValue).tag(category)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 16)

            switch pane {
            case .files: DeviceFilesView(workspace: workspace)
            case .mail: ToolkitMailView(workspace: workspace)
            case .local: ToolkitLocalView(workspace: workspace)
            case .sources: ToolkitSourcesView(workspace: workspace)
            case .commands: ToolkitCommandsView(workspace: workspace)
            case .native: ToolkitNativeResourcesView()
            case .notifications: ToolkitNotificationsView(notifications: workspace.toolkitNotifications)
            case .computer: ComputerUseView(workspace: workspace)
            case .github: ToolkitGitHubView(workspace: workspace)
            case .audit: ToolkitAuditView(workspace: workspace)
            }
        }
    }
}

struct ToolkitFolderPicker: View {
    let workspace: Workspace
    @Binding var selection: UUID?
    let label: String

    var body: some View {
        Picker(label, selection: $selection) {
            Text("No Toolkit folder").tag(UUID?.none)
            ForEach(workspace.fileRelay.manifest.grants) { grant in
                Text("\(grant.name) · \(workspace.toolkitDeviceName(grant.deviceID))").tag(Optional(grant.id))
            }
        }
        .accessibilityLabel(label)
        .help("The local model can propose a file action within this folder. Confirm the proposal to run it.")
        .onChange(of: workspace.fileRelay.manifest.grants.map(\.id)) { _, resources in
            if let selection, !resources.contains(selection) {
                self.selection = nil
            }
        }
    }
}
