import AppKit
import ScreenCaptureKit
import SwiftUI

struct ToolkitComputerView: View {
    private static let allowedApps: Set<String> = [
        "com.apple.calculator", "com.apple.Dictionary", "com.apple.iWork.Keynote",
        "com.apple.iWork.Numbers", "com.apple.iWork.Pages", "com.apple.Preview", "com.apple.TextEdit",
    ]

    @ViewState private var availableApps: [DesktopApp] = []
    @ViewState private var windows: [DesktopWindow] = []
    @ViewState private var appPID: pid_t?
    @ViewState private var windowID: CGWindowID?
    @ViewState private var action: DesktopAction?
    @ViewState private var snapshot: CGImage?
    @ViewState private var busy = false
    @ViewState private var status: String?
    @ViewState private var error: String?

    var body: some View {
        Form {
            Section("App on this Mac") {
                Button("Refresh running apps", action: refreshApps)
                Picker("App", selection: $appPID) {
                    Text("Choose an app").tag(pid_t?.none)
                    ForEach(availableApps) { app in
                        Text(app.name).tag(Optional(app.id))
                    }
                }
                if let app = availableApps.first(where: { $0.id == appPID }) {
                    HStack {
                        Button("Review activation…") { action = .activate(app) }
                        Button("Choose a window…") { Task { await listWindows(for: app) } }
                    }
                }
                if windows.isEmpty && availableApps.isEmpty {
                    Text("Open an app such as TextEdit, Preview, Calculator, or Dictionary first.")
                        .foregroundStyle(.secondary)
                }
            }
            if !windows.isEmpty, let app = availableApps.first(where: { $0.id == appPID }) {
                Section("Window preview") {
                    Picker("Window", selection: $windowID) {
                        Text("Choose a window").tag(CGWindowID?.none)
                        ForEach(windows) { window in
                            Text(window.title).tag(Optional(window.id))
                        }
                    }
                    if let window = windows.first(where: { $0.id == windowID }) {
                        Button("Review snapshot…") { action = .snapshot(app, window) }
                    }
                    if let snapshot {
                        Image(decorative: snapshot, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 360)
                            .accessibilityLabel("Approved window preview")
                        Button("Clear preview") { self.snapshot = nil }
                    }
                }
            }
            if let status {
                Section { Text(status).foregroundStyle(.secondary) }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
        .task { refreshApps() }
        .onChange(of: appPID) { _, _ in clearWindows() }
        .onChange(of: windowID) { _, _ in snapshot = nil }
        .onDisappear {
            clearWindows()
            appPID = nil
            action = nil
        }
        .confirmationDialog("Approve one desktop action?", isPresented: Binding(
            get: { action != nil },
            set: { if !$0 { action = nil } }
        ), presenting: action) { action in
            Button(action.button) { Task { await perform(action) } }
        } message: { action in
            Text(action.summary)
        }
    }

    private func refreshApps() {
        availableApps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier, Self.allowedApps.contains(bundleID),
                  app.activationPolicy == .regular, let name = app.localizedName else { return nil }
            return DesktopApp(id: app.processIdentifier, bundleID: bundleID, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !availableApps.contains(where: { $0.id == appPID }) { appPID = nil }
    }

    private func clearWindows() {
        windows = []
        windowID = nil
        snapshot = nil
        error = nil
        status = nil
    }

    private func listWindows(for app: DesktopApp) async {
        guard !busy else { return }
        clearWindows()
        busy = true
        defer { busy = false }
        do {
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                throw DesktopAccessError.permission
            }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard appPID == app.id, !Task.isCancelled else { return }
            windows = content.windows.filter { Self.isWindow($0, in: app) }.map {
                let title = $0.title?.trimmed ?? ""
                return DesktopWindow(id: $0.windowID, title: title.isEmpty ? "Window \($0.windowID)" : title)
            }
            if windows.isEmpty { status = "No on-screen windows are available for this app." }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func perform(_ action: DesktopAction) async {
        guard !busy else { return }
        busy = true
        error = nil
        status = nil
        defer { busy = false }
        do {
            switch action {
            case .activate(let app):
                guard let current = NSRunningApplication(processIdentifier: app.id),
                      current.bundleIdentifier == app.bundleID, Self.allowedApps.contains(app.bundleID), !current.isTerminated,
                      current.activate() else { throw DesktopAccessError.unavailable }
            case .snapshot(let app, let selected):
                guard CGPreflightScreenCaptureAccess() else { throw DesktopAccessError.permission }
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: {
                    $0.windowID == selected.id && Self.isWindow($0, in: app)
                }) else { throw DesktopAccessError.unavailable }
                guard appPID == app.id, windowID == selected.id, !Task.isCancelled else { return }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let settings = SCStreamConfiguration()
                let scale = min(1, 1200 / max(window.frame.width, window.frame.height, 1))
                settings.width = max(1, Int(window.frame.width * scale))
                settings.height = max(1, Int(window.frame.height * scale))
                settings.showsCursor = false
                settings.capturesAudio = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: settings)
                if appPID == app.id, windowID == selected.id, !Task.isCancelled { snapshot = image }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func isWindow(_ window: SCWindow, in app: DesktopApp) -> Bool {
        allowedApps.contains(app.bundleID) && window.windowLayer == 0 && window.isOnScreen &&
            window.owningApplication?.processID == app.id && window.owningApplication?.bundleIdentifier == app.bundleID
    }
}

private struct DesktopApp: Identifiable {
    let id: pid_t
    let bundleID: String
    let name: String
}

private struct DesktopWindow: Identifiable {
    let id: CGWindowID
    let title: String
}

private enum DesktopAction {
    case activate(DesktopApp)
    case snapshot(DesktopApp, DesktopWindow)

    var button: String {
        switch self {
        case .activate: "Confirm and activate"
        case .snapshot: "Confirm and capture"
        }
    }

    var summary: String {
        switch self {
        case .activate(let app): "Bring \(app.name) to the front."
        case .snapshot(let app, let window): "Take one local snapshot of \(window.title) in \(app.name)."
        }
    }
}

private enum DesktopAccessError: LocalizedError {
    case permission, unavailable

    var errorDescription: String? {
        switch self {
        case .permission: "Allow screen recording in macOS Privacy & Security to preview one selected window."
        case .unavailable: "The app or window is no longer available. Choose it again."
        }
    }
}
