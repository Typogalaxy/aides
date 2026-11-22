import AppKit
@preconcurrency import ApplicationServices
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
    @ViewState private var digit = 0
    @ViewState private var snapshot: CGImage?
    @ViewState private var busy = false
    @ViewState private var status: String?
    @ViewState private var error: String?
    @ViewState private var accessibilityEnabled = false

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
                        if app.bundleID == CalculatorButton.bundleID {
                            if accessibilityEnabled {
                                Picker("Calculator key", selection: $digit) {
                                    ForEach(0...9, id: \.self) { digit in Text(String(digit)).tag(digit) }
                                }
                                Button("Review Calculator keypress…") { action = .calculatorDigit(app, window, digit) }
                            } else {
                                Button("Allow Calculator control…") { requestAccessibility() }
                            }
                        }
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
        .task {
            refreshApps()
            accessibilityEnabled = AXIsProcessTrusted()
        }
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
            return DesktopApp(id: app.processIdentifier, bundleID: bundleID, name: name, launchedAt: app.launchDate)
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
            case .calculatorDigit(let app, let selected, let digit):
                try await pressCalculatorDigit(digit, app: app, window: selected)
                status = "Pressed \(digit) in Calculator."
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

    private func requestAccessibility() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        accessibilityEnabled = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        status = accessibilityEnabled ? nil : "Grant Aides Accessibility access in System Settings, then use this button again."
    }

    private func pressCalculatorDigit(_ digit: Int, app: DesktopApp, window selected: DesktopWindow) async throws {
        guard AXIsProcessTrusted() else {
            accessibilityEnabled = false
            throw DesktopAccessError.accessibilityPermission
        }
        let aidesPID = ProcessInfo.processInfo.processIdentifier
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == aidesPID,
              let running = CalculatorButton.validate(app), running.activate() else {
            throw DesktopAccessError.calculatorSelection
        }
        for _ in 0..<10 {
            try Task.checkCancellation()
            guard appPID == app.id, windowID == selected.id else { throw CancellationError() }
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontPID == app.id { break }
            guard frontPID == aidesPID else { throw DesktopAccessError.calculatorSelection }
            try await Task.sleep(for: .milliseconds(75))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.id else {
            throw DesktopAccessError.calculatorSelection
        }
        guard CGPreflightScreenCaptureAccess() else { throw DesktopAccessError.permission }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let appWindows = content.windows.filter { Self.isWindow($0, in: app) }
        guard appPID == app.id, windowID == selected.id, !Task.isCancelled else { throw CancellationError() }
        guard appWindows.count == 1, let window = appWindows.first, window.windowID == selected.id else {
            throw DesktopAccessError.calculatorSelection
        }
        try CalculatorButton.press(digit, app: app, in: window)
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
    let launchedAt: Date?
}

private struct DesktopWindow: Identifiable {
    let id: CGWindowID
    let title: String
}

private enum DesktopAction {
    case activate(DesktopApp)
    case snapshot(DesktopApp, DesktopWindow)
    case calculatorDigit(DesktopApp, DesktopWindow, Int)

    var button: String {
        switch self {
        case .activate: "Confirm and activate"
        case .snapshot: "Confirm and capture"
        case .calculatorDigit(_, _, let digit): "Confirm and press \(digit)"
        }
    }

    var summary: String {
        switch self {
        case .activate(let app): "Bring \(app.name) to the front."
        case .snapshot(let app, let window): "Take one local snapshot of \(window.title) in \(app.name)."
        case .calculatorDigit(_, let window, let digit): "Bring \(window.title) to the front and press Calculator’s \(digit) button once."
        }
    }
}

private enum DesktopAccessError: LocalizedError {
    case permission, unavailable, accessibilityPermission, calculatorSelection, calculatorPress

    var errorDescription: String? {
        switch self {
        case .permission: "Allow screen recording in macOS Privacy & Security to preview one selected window."
        case .unavailable: "The app or window is no longer available. Choose it again."
        case .accessibilityPermission: "Allow Accessibility access in macOS Privacy & Security to press a Calculator button."
        case .calculatorSelection: "The selected Calculator window or numeric button could not be verified. Keep only that Calculator window open and try again."
        case .calculatorPress: "Calculator did not confirm the press. Check its display before trying again."
        }
    }
}


@MainActor
private enum CalculatorButton {
    static let bundleID = "com.apple.calculator"

    static func validate(_ app: DesktopApp) -> NSRunningApplication? {
        guard app.bundleID == bundleID, let launchedAt = app.launchedAt,
              let running = NSRunningApplication(processIdentifier: app.id),
              !running.isTerminated, running.activationPolicy == .regular, running.launchDate == launchedAt,
              running.bundleIdentifier == bundleID,
              running.bundleURL?.resolvingSymlinksInPath().path == "/System/Applications/Calculator.app" else {
            return nil
        }
        return running
    }

    static func press(_ digit: Int, app: DesktopApp, in window: SCWindow) throws {
        guard (0...9).contains(digit), AXIsProcessTrusted(), validate(app) != nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.id else {
            throw DesktopAccessError.calculatorSelection
        }
        let title = String(digit)
        let application = AXUIElementCreateApplication(app.id)
        guard AXUIElementSetMessagingTimeout(application, 0.2) == .success,
              let windowElement = element(attribute(application, kAXFocusedWindowAttribute)),
              let axWindows = attribute(application, kAXWindowsAttribute) as? [AXUIElement],
              axWindows.count == 1, let onlyWindow = axWindows.first, CFEqual(windowElement, onlyWindow),
              let position = point(attribute(windowElement, kAXPositionAttribute)),
              let size = size(attribute(windowElement, kAXSizeAttribute)),
              abs(position.x - window.frame.minX) <= 3, abs(position.y - window.frame.minY) <= 3,
              abs(size.width - window.frame.width) <= 3, abs(size.height - window.frame.height) <= 3,
              let button = try uniqueButton(titled: title, in: windowElement) else {
            throw DesktopAccessError.calculatorSelection
        }
        var buttonPID: pid_t = 0
        guard AXUIElementGetPid(button, &buttonPID) == .success, buttonPID == app.id, isButton(button, titled: title),
              let focused = element(attribute(application, kAXFocusedWindowAttribute)),
              CFEqual(focused, windowElement), validate(app) != nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.id else {
            throw DesktopAccessError.calculatorSelection
        }
        // One approved action, with no fallback or retry even if the target times out.
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            throw DesktopAccessError.calculatorPress
        }
    }

    private static func uniqueButton(titled title: String, in window: AXUIElement) throws -> AXUIElement? {
        let limit = 128
        let deadline = ContinuousClock.now + .seconds(1)
        var remaining = [window]
        var examined = 0
        var match: AXUIElement?
        while let node = remaining.popLast() {
            guard examined < limit, ContinuousClock.now < deadline else { throw DesktopAccessError.calculatorSelection }
            examined += 1
            if isButton(node, titled: title) {
                var actions: CFArray?
                if AXUIElementCopyActionNames(node, &actions) == .success,
                   (actions as? [String])?.contains(kAXPressAction) == true {
                    guard match == nil else { throw DesktopAccessError.calculatorSelection }
                    match = node
                }
            }
            var count = 0
            let result = AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &count)
            if result == .attributeUnsupported || result == .noValue { continue }
            guard result == .success, count <= limit - examined - remaining.count else {
                throw DesktopAccessError.calculatorSelection
            }
            if count == 0 { continue }
            var children: CFArray?
            guard AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, count, &children) == .success,
                  let elements = children as? [AXUIElement], elements.count == count else {
                throw DesktopAccessError.calculatorSelection
            }
            remaining.append(contentsOf: elements)
        }
        return match
    }

    private static func isButton(_ node: AXUIElement, titled title: String) -> Bool {
        attribute(node, kAXRoleAttribute) as? String == kAXButtonRole &&
            attribute(node, kAXEnabledAttribute) as? Bool == true &&
            [kAXTitleAttribute, kAXDescriptionAttribute].contains { attribute(node, $0) as? String == title }
    }

    private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func point(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}
