import SwiftUI

// Use the SwiftUI property wrapper on both full Xcode and Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct AidesDesktopApp: App {
    @ViewState private var workspace = Workspace()
    @ViewState private var updates = DesktopUpdates()
    @AppStorage("aides.appearance") private var appearance = DesktopAppearance.system

    var body: some Scene {
        WindowGroup {
            WorkspaceView(workspace: workspace, updates: updates)
                .preferredColorScheme(appearance.colorScheme)
                .frame(minWidth: 820, minHeight: 550)
                .task {
                    updates.start()
                    await workspace.restore()
                }
        }
        .defaultSize(width: 1230, height: 800)
        .commands {
            CommandMenu("Computer Use") {
                Button("Pause Desktop Task") {
                    if let run = workspace.computerRelay.activeLocalRun {
                        Task { await workspace.computerRelay.control(run, .pause) }
                    }
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(workspace.computerRelay.activeLocalRun == nil)
            }
            CommandGroup(after: .appInfo) {
                if updates.isAvailable {
                    Button("Check for Updates…") { updates.check() }
                }
            }
        }
    }
}

enum DesktopAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
