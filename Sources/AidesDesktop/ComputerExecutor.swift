import AidesCore
import AppKit
@preconcurrency import ApplicationServices
import Carbon
import CryptoKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Runs against one interactive macOS session. Handles never leave this Mac.
@MainActor
final class ComputerExecutor {
    private let allowedAppIDs: [String]
    private let includeImages: Bool
    private let allowBackground: Bool
    private var approvedWindows: [String: Window] = [:]
    private var activeAppID: String?
    private var ownedForegroundPID: pid_t?
    private var elements: [String: ObservedElement] = [:]
    private var lastObservation: ComputerObservation?
    private var lastFocused: AXUIElement?
    private var imageCapturedAt: ContinuousClock.Instant?
    private var lastObservationWasBackground = false
    private var lastInput: TimeInterval?
    private var stopped = false
    private var reviewedRefocus = false

    init(allowedAppIDs: [String], includeImages: Bool, allowBackground: Bool = false) {
        self.allowedAppIDs = allowedAppIDs.filter(Self.isEligible)
        self.includeImages = includeImages
        self.allowBackground = allowBackground
    }

    static func runningApps() -> [ComputerApp] {
        var seen: Set<String> = []
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated,
                  let id = app.bundleIdentifier, isEligible(id),
                  let name = app.localizedName, seen.insert(id).inserted else { return nil }
            return ComputerApp(id: id, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func availableApps() -> [ComputerApp] {
        var byID = Dictionary(uniqueKeysWithValues: runningApps().map { ($0.id, $0) })
        let manager = FileManager.default
        let roots = manager.urls(for: .applicationDirectory, in: [.userDomainMask, .localDomainMask, .systemDomainMask])
        for root in roots {
            for directory in [root, root.appending(path: "Utilities", directoryHint: .isDirectory)] {
                guard let urls = try? manager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                ) else { continue }
                for url in urls.prefix(256) where url.pathExtension.lowercased() == "app" {
                    guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                          byID[id] == nil, isEligible(id),
                          registeredAppURL(id)?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() else { continue }
                    let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? url.deletingPathExtension().lastPathComponent
                    byID[id] = ComputerApp(id: id, name: name)
                }
            }
        }
        return byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func captureFrontmost(includeImage: Bool) async throws -> ComputerObservation {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
              isEligible(id) else { throw Failure.appNotAllowed }
        let executor = ComputerExecutor(allowedAppIDs: [id], includeImages: includeImage)
        return try await executor.observe(id, requiringForeground: true)
    }

    func execute(_ action: ComputerAction) async throws -> ComputerObservation {
        do {
            return try await perform(action)
        } catch {
            // An action can have succeeded before observation failed. A fresh run
            // requires a fresh observation and its own authorization.
            stop()
            throw error
        }
    }

    static func approvalInputEpoch() -> TimeInterval {
        recentInput()
    }

    /// Uses the input sample taken when the local approval UI accepted the exact command.
    func acknowledgeReviewedAction(inputEpoch: TimeInterval) {
        guard !stopped else { return }
        lastInput = inputEpoch
        reviewedRefocus = true
    }

    func stop() {
        stopped = true
        elements.removeAll()
        approvedWindows.removeAll()
        lastObservation = nil
        lastFocused = nil
        imageCapturedAt = nil
    }

    private func perform(_ action: ComputerAction) async throws -> ComputerObservation {
        try Task.checkCancellation()
        guard !stopped else { throw Failure.unavailable }
        guard action.isValid(allowedAppIDs: allowedAppIDs, observation: lastObservation) else { throw Failure.invalidAction }
        if action.kind == .finish || action.kind == .handoff {
            guard let observation = lastObservation else { throw Failure.unavailable }
            stop()
            return observation
        }
        try requireInteractiveSession()

        guard let appID = action.appID ?? activeAppID ?? allowedAppIDs.first,
              allowedAppIDs.contains(appID) else { throw Failure.appNotAllowed }
        let app = try await obtainApp(appID, for: action.kind)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let background = allowBackground && frontmost != app.processIdentifier
        if !background || (activeAppID == appID && !lastObservationWasBackground) {
            try requireNoNewInput()
        }
        if allowBackground && !action.supportsBackground { throw Failure.backgroundUnsupported }
        if action.kind == .activate {
            guard frontmost == app.processIdentifier || frontmost == ownedForegroundPID
                    || frontmost == ProcessInfo.processInfo.processIdentifier else { throw Failure.takeover }
            if frontmost != app.processIdentifier {
                guard app.activate() else { throw Failure.unavailable }
                for _ in 0..<12 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                    try await Task.sleep(for: .milliseconds(50))
                    try requireInteractiveSession()
                    try requireNoNewInput()
                    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    guard front == app.processIdentifier || front == frontmost else { throw Failure.takeover }
                }
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                throw Failure.unavailable
            }
            return try await observe(appID)
        }
        if action.kind == .observe {
            // A request to inspect another app uses its own approved app scope.
            return try await observe(appID, background: background)
        }

        guard activeAppID == appID, let pinned = approvedWindows[appID] else { throw Failure.staleObservation }
        let wasReviewed = reviewedRefocus
        if wasReviewed {
            reviewedRefocus = false
            let aidePID = ProcessInfo.processInfo.processIdentifier
            if !allowBackground && NSWorkspace.shared.frontmostApplication?.processIdentifier == aidePID {
                try await restoreApprovedForeground(pinned)
            }
        }
        let live = try window(in: appID, requiringForeground: !background)
        guard pinned.matches(live) else { throw Failure.staleObservation }
        try requireSafeFocus(live)
        if !background { try requireNoNewInput() }
        switch action.kind {
        case .click:
            let simpleLeft = (action.clickCount ?? 1) == 1 && action.button != .right
            if simpleLeft, action.elementID != nil {
                try click(action, in: live, background: background)
            } else if simpleLeft, let target = try? targetElement(action, in: live),
                      Self.editableRoles.contains(target.description.role) || Self.pressableRoles.contains(target.description.role) {
                try click(action, in: live, background: background)
            } else {
                try await pointer(action, in: live, reviewed: wasReviewed)
            }
        case .drag, .movePointer:
            try await pointer(action, in: live, reviewed: wasReviewed)
        case .typeText:
            try type(action, in: live, background: background)
        case .key:
            try sendKey(action, in: live)
        case .scroll:
            try scroll(action, in: live)
        case .observe, .activate, .finish, .handoff:
            throw Failure.invalidAction
        }

        try await Task.sleep(for: .milliseconds(150))
        return try await observe(appID, requiringForeground: !background, background: background)
    }

    private func restoreApprovedForeground(_ pinned: Window) async throws {
        let app = try resolveApp(pinned.identity.appID)
        let aidePID = ProcessInfo.processInfo.processIdentifier
        guard app.processIdentifier == pinned.identity.pid, app.launchDate == pinned.identity.launch,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == aidePID, app.activate() else {
            throw Failure.takeover
        }
        for _ in 0..<12 {
            try Task.checkCancellation()
            try requireInteractiveSession()
            try requireNoNewInput()
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if front == pinned.identity.pid { return }
            guard front == aidePID else { throw Failure.takeover }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.unavailable
    }

    private func observe(
        _ appID: String, requiringForeground: Bool = false, background: Bool = false
    ) async throws -> ComputerObservation {
        try requireInteractiveSession()
        if !background { try requireNoNewInput() }
        let inputBefore = Self.recentInput()
        let target = try window(in: appID, requiringForeground: requiringForeground)
        if let approved = approvedWindows[appID] {
            guard approved.matches(target) else { throw Failure.staleObservation }
        }
        try requireSafeFocus(target)
        let focusedBefore = Self.element(Self.attribute(target.application, kAXFocusedUIElementAttribute))
        var scan = try inspect(target, focused: focusedBefore)
        if appID == "com.apple.TextEdit" && !allowBackground {
            scan.elements.append(contentsOf: Self.textEditMenuItems(in: target))
        }

        var screenshot: Data?
        var notices: [String] = []
        if allowBackground {
            notices.append("This task uses non-activating accessibility controls. Use observed control IDs. Activation, coordinates, menu actions, navigation keys, and scrolling are unavailable in this mode.")
        }
        if includeImages {
            if scan.complete && !scan.containsProtectedElement && CGPreflightScreenCaptureAccess() {
                screenshot = try await capture(target)
            }
            if screenshot == nil {
                notices.append("A window image could not be safely captured.")
            }
        }

        try Task.checkCancellation()
        try requireInteractiveSession()
        let current = try window(in: appID, requiringForeground: requiringForeground)
        guard target.matches(current) else { throw Failure.staleObservation }
        try requireSafeFocus(current)
        let focusedAfter = Self.element(Self.attribute(current.application, kAXFocusedUIElementAttribute))
        guard Self.sameElement(focusedBefore, focusedAfter) else { throw Failure.staleObservation }
        if background {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != current.identity.pid else {
                throw Failure.takeover
            }
        } else {
            guard Self.recentInput() <= inputBefore + 0.025 else { throw Failure.takeover }
        }

        approvedWindows[appID] = current
        activeAppID = appID
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == current.identity.pid {
            ownedForegroundPID = current.identity.pid
        }
        elements = Dictionary(uniqueKeysWithValues: scan.elements.map { ($0.description.id, $0) })
        lastInput = background ? Self.recentInput() : inputBefore
        lastObservationWasBackground = background
        let observation = ComputerObservation(
            appID: appID,
            windowTitle: Self.text(Self.attribute(current.ax, kAXTitleAttribute))?.prefixText(180) ?? "Window",
            elements: scan.elements.map(\.description),
            screenshot: screenshot,
            notice: notices.isEmpty ? nil : notices.joined(separator: " "),
            isBackground: allowBackground ? true : nil
        )
        lastFocused = focusedAfter
        imageCapturedAt = screenshot == nil ? nil : .now
        lastObservation = observation
        return observation
    }

    private func window(in appID: String, requiringForeground: Bool) throws -> Window {
        let app = try resolveApp(appID)
        if requiringForeground && NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            throw Failure.takeover
        }
        guard let launch = app.launchDate else { throw Failure.unavailable }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        if AXUIElementSetMessagingTimeout(application, 0.16) != .success { throw Failure.unavailable }
        let focused = Self.element(Self.attribute(application, kAXFocusedWindowAttribute))
        let main = requiringForeground ? nil : Self.element(Self.attribute(application, kAXMainWindowAttribute))
        guard let focused = focused ?? main,
              Self.attribute(focused, kAXRoleAttribute) as? String == kAXWindowRole,
              Self.attribute(focused, kAXMinimizedAttribute) as? Bool != true,
              let frame = Self.frame(focused) else { throw Failure.unavailable }
        return Window(identity: Identity(appID: appID, pid: app.processIdentifier, launch: launch),
                      application: application, ax: focused, frame: frame)
    }

    private func obtainApp(_ appID: String, for action: ComputerActionKind) async throws -> NSRunningApplication {
        if let running = try? resolveApp(appID) { return running }
        guard !allowBackground, allowedAppIDs.contains(appID), Self.isEligible(appID),
              NSRunningApplication.runningApplications(withBundleIdentifier: appID).isEmpty,
              action == .activate || (action == .observe && activeAppID == nil),
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              front == ProcessInfo.processInfo.processIdentifier || front == ownedForegroundPID,
              let url = Self.registeredAppURL(appID) else {
            throw Failure.unavailable
        }
        try Task.checkCancellation()
        try requireNoNewInput()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        let launched = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        try Task.checkCancellation()
        try requireInteractiveSession()
        try requireNoNewInput()
        guard launched.bundleIdentifier == appID, launched.bundleURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath(),
              let current = try? resolveApp(appID), current.processIdentifier == launched.processIdentifier else {
            throw Failure.unavailable
        }
        for _ in 0..<16 {
            try Task.checkCancellation()
            try requireInteractiveSession()
            try requireNoNewInput()
            let focused = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard focused == current.processIdentifier || focused == front else { throw Failure.takeover }
            if focused == current.processIdentifier, (try? window(in: appID, requiringForeground: true)) != nil {
                return current
            }
            try await Task.sleep(for: .milliseconds(75))
        }
        throw Failure.unavailable
    }

    private static func registeredAppURL(_ appID: String) -> URL? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID),
              url.isFileURL, url.pathExtension.lowercased() == "app", Bundle(url: url)?.bundleIdentifier == appID else {
            return nil
        }
        return url
    }

    private func resolveApp(_ appID: String) throws -> NSRunningApplication {
        guard allowedAppIDs.contains(appID), Self.isEligible(appID) else { throw Failure.appNotAllowed }
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: appID).filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }
        guard instances.count == 1, let app = instances.first,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw Failure.unavailable }
        return app
    }

    private func requireSafeFocus(_ window: Window) throws {
        guard !IsSecureEventInputEnabled() else { throw Failure.protectedContent }
        if let focused = Self.element(Self.attribute(window.application, kAXFocusedUIElementAttribute)) {
            guard !Self.isProtected(focused) else { throw Failure.protectedContent }
        }
    }

    static func sessionIsInteractive() -> Bool {
        AXIsProcessTrusted() && consoleIsAvailable() && !IsSecureEventInputEnabled()
    }

    private func requireInteractiveSession() throws {
        guard AXIsProcessTrusted() else { throw Failure.accessibilityPermission }
        guard Self.consoleIsAvailable() else { throw Failure.locked }
    }

    private static func consoleIsAvailable() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session["kCGSSessionOnConsoleKey"] as? Bool == true,
              session["kCGSessionLoginDoneKey"] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true,
              let foreground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              !isSecurityApp(foreground) else { return false }
        return true
    }

    private func requireNoNewInput() throws {
        if let lastInput, Self.recentInput() > lastInput + 0.025 { throw Failure.takeover }
    }

    private static func recentInput() -> TimeInterval {
        let types: [CGEventType] = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel
        ]
        let elapsed = types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
        return ProcessInfo.processInfo.systemUptime - elapsed
    }

    private func inspect(_ window: Window, focused: AXUIElement?) throws -> Scan {
        let deadline = ContinuousClock.now + .milliseconds(850)
        var pending = [(window.ax, 0)]
        var examined = 0
        var result = Scan()
        var byteCount = 0
        if let focused, Self.belongs(focused, to: window), let item = Self.describe(focused) {
            result.elements.append(item)
            byteCount = item.description.label.utf8.count + (item.description.value?.utf8.count ?? 0)
        }
        while let (node, depth) = pending.popLast() {
            try Task.checkCancellation()
            guard examined < 220, ContinuousClock.now < deadline else {
                result.complete = false
                break
            }
            examined += 1
            if Self.isProtected(node) {
                result.containsProtectedElement = true
                continue
            }
            if result.elements.count < 80, !Self.sameElement(focused, node), let item = Self.describe(node) {
                let count = item.description.label.utf8.count + (item.description.value?.utf8.count ?? 0)
                if byteCount + count <= 23_000 {
                    result.elements.append(item)
                    byteCount += count
                }
            }
            var childCount = 0
            let status = AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &childCount)
            if status == .attributeUnsupported || status == .noValue { continue }
            guard status == .success, childCount > 0 else {
                if status != .success { result.complete = false }
                continue
            }
            let limit = min(childCount, 64, 220 - examined - pending.count)
            guard depth < 14, limit > 0 else {
                result.complete = false
                continue
            }
            var children: CFArray?
            guard AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, limit, &children) == .success,
                  let values = children as? [AXUIElement] else {
                result.complete = false
                continue
            }
            if values.count < childCount { result.complete = false }
            pending.append(contentsOf: values.reversed().map { ($0, depth + 1) })
        }
        return result
    }

    private func click(_ action: ComputerAction, in window: Window, background: Bool) throws {
        let observed = try targetElement(action, in: window)
        if observed.menuKind != nil {
            guard !allowBackground else { throw Failure.backgroundUnsupported }
            try pressMenu(observed, in: window)
            return
        }
        guard let role = Self.attribute(observed.ax, kAXRoleAttribute) as? String,
              observed.stillMatches(), role == observed.description.role, !Self.isProtected(observed.ax),
              Self.attribute(observed.ax, kAXEnabledAttribute) as? Bool != false else {
            throw Failure.staleObservation
        }
        if Self.editableRoles.contains(role) {
            guard !allowBackground else { throw Failure.backgroundUnsupported }
            guard Self.settable(observed.ax, kAXFocusedAttribute) else { throw Failure.unsupportedControl }
            try requireUnchanged(window, background: background)
            guard AXUIElementSetAttributeValue(observed.ax, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
                throw Failure.operationUnknown
            }
        } else {
            guard Self.pressableRoles.contains(role), Self.supports(observed.ax, kAXPressAction) else {
                throw Failure.unsupportedControl
            }
            try requireUnchanged(window, background: background)
            guard AXUIElementPerformAction(observed.ax, kAXPressAction as CFString) == .success else {
                throw Failure.operationUnknown
            }
        }
    }

    private func pointer(_ action: ComputerAction, in window: Window, reviewed: Bool) async throws {
        guard reviewed, !allowBackground, let imageCapturedAt,
              ContinuousClock.now - imageCapturedAt <= .seconds(90),
              let x = action.x, let y = action.y,
              let source = CGEventSource(stateID: .privateState) else { throw Failure.pointerReview }
        let start = try pointerPoint(x: x, y: y, in: window)
        try validatePointerHit(start, in: window)
        try requireUnchanged(window)
        let pid = window.identity.pid
        switch action.kind {
        case .movePointer:
            guard let event = mouse(.mouseMoved, at: start, button: .left, source: source, clickCount: 0) else {
                throw Failure.unavailable
            }
            event.postToPid(pid)
        case .click:
            let button: CGMouseButton = action.button == .right ? .right : .left
            let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
            let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
            for count in 1...(action.clickCount ?? 1) {
                try requireUnchanged(window)
                try validatePointerHit(start, in: window)
                guard let press = mouse(down, at: start, button: button, source: source, clickCount: count),
                      let release = mouse(up, at: start, button: button, source: source, clickCount: count) else {
                    throw Failure.unavailable
                }
                press.postToPid(pid)
                release.postToPid(pid)
                if count == 1, action.clickCount == 2 {
                    try await Task.sleep(for: .milliseconds(45))
                }
            }
        case .drag:
            guard let endX = action.endX, let endY = action.endY else { throw Failure.invalidAction }
            let end = try pointerPoint(x: endX, y: endY, in: window)
            try validatePointerHit(end, in: window)
            try await drag(from: start, to: end, in: window, source: source)
        default:
            throw Failure.invalidAction
        }
    }

    private func drag(from start: CGPoint, to end: CGPoint, in window: Window, source: CGEventSource) async throws {
        let count = 8
        let points = (1...count).map { index in
            let fraction = Double(index) / Double(count)
            return CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
        }
        for point in points { try validatePointerHit(point, in: window) }
        try requireUnchanged(window)
        guard let down = mouse(.leftMouseDown, at: start, button: .left, source: source, clickCount: 1),
              let release = mouse(.leftMouseUp, at: start, button: .left, source: source, clickCount: 1) else {
            throw Failure.unavailable
        }
        var last = start
        down.postToPid(window.identity.pid)
        defer {
            // Release has priority after a local takeover, but it must never target a recycled PID.
            if let running = NSRunningApplication(processIdentifier: window.identity.pid),
               !running.isTerminated, running.launchDate == window.identity.launch,
               running.bundleIdentifier == window.identity.appID {
                release.location = last
                release.postToPid(window.identity.pid)
            }
        }
        for point in points {
            try await Task.sleep(for: .milliseconds(22))
            try requireUnchanged(window)
            try validatePointerHit(point, in: window)
            guard let event = mouse(.leftMouseDragged, at: point, button: .left, source: source, clickCount: 1) else {
                throw Failure.operationUnknown
            }
            event.postToPid(window.identity.pid)
            last = point
        }
    }

    private func mouse(
        _ type: CGEventType, at point: CGPoint, button: CGMouseButton, source: CGEventSource, clickCount: Int
    ) -> CGEvent? {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.flags = []
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        return event
    }

    private func pointerPoint(x: Double, y: Double, in window: Window) throws -> CGPoint {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
              window.frame.width > 2, window.frame.height > 2 else { throw Failure.invalidAction }
        return CGPoint(
            x: min(window.frame.maxX - 1, window.frame.minX + max(1, x * window.frame.width)),
            y: min(window.frame.maxY - 1, window.frame.minY + max(1, y * window.frame.height))
        )
    }

    private func validatePointerHit(_ point: CGPoint, in window: Window) throws {
        var hit: AXUIElement?
        guard window.frame.contains(point),
              AXUIElementCopyElementAtPosition(window.application, Float(point.x), Float(point.y), &hit) == .success,
              let hit, Self.belongs(hit, to: window) else { throw Failure.staleObservation }
        var current: AXUIElement? = hit
        for _ in 0..<16 {
            guard let node = current, !Self.isProtected(node), !Self.isWindowButton(node),
                  Self.attribute(node, kAXRoleAttribute) as? String != "AXLink" else {
                throw Failure.protectedContent
            }
            if CFEqual(node, window.ax) { return }
            current = Self.element(Self.attribute(node, kAXParentAttribute))
        }
        throw Failure.staleObservation
    }

    private func pressMenu(_ observed: ObservedElement, in window: Window) throws {
        guard let kind = observed.menuKind, window.identity.appID == "com.apple.TextEdit",
              Self.textEditMenuItems(in: window).contains(where: {
                  $0.menuKind == kind && CFEqual($0.ax, observed.ax) && $0.description.label == observed.description.label
              }) else { throw Failure.staleObservation }
        try requireUnchanged(window)
        guard AXUIElementPerformAction(observed.ax, kAXPressAction as CFString) == .success else {
            throw Failure.operationUnknown
        }
    }

    private func type(_ action: ComputerAction, in window: Window, background: Bool) throws {
        guard let text = action.text, !text.isEmpty, text.utf8.count <= 4_096, !text.utf8.contains(0),
              let focused = Self.element(Self.attribute(window.application, kAXFocusedUIElementAttribute)),
              let role = Self.attribute(focused, kAXRoleAttribute) as? String, Self.editableRoles.contains(role),
              !Self.isProtected(focused), Self.belongs(focused, to: window),
              let id = action.elementID, let expected = elements[id], CFEqual(expected.ax, focused) else {
            throw Failure.unsupportedControl
        }
        guard let range = expected.selection, let fingerprint = expected.selectionFingerprint,
              expected.stillMatches() else { throw Failure.staleObservation }
        if Self.settable(focused, kAXSelectedTextAttribute) {
            try requireUnchanged(window, focused: focused, background: background)
            guard Self.selection(focused) == range, Self.fingerprint(focused, range: range) == fingerprint else {
                throw Failure.staleObservation
            }
            guard AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
                throw Failure.operationUnknown
            }
            return
        }

        // A single-line field may support setting its plain value without providing
        // a setter for selected text. Reconstruct its value using the exact UTF-16 range.
        guard role == kAXTextFieldRole, Self.settable(focused, kAXValueAttribute),
              let original = Self.attribute(focused, kAXValueAttribute) as? String,
              original.utf8.count <= 16_384, let stringRange = Range(range, in: original) else {
            throw Failure.unsupportedControl
        }
        let replacement = original.replacingCharacters(in: stringRange, with: text)
        try requireUnchanged(window, focused: focused, background: background)
        guard Self.selection(focused) == range, Self.fingerprint(focused, range: range) == fingerprint,
              (Self.attribute(focused, kAXValueAttribute) as? String)?.utf8.elementsEqual(original.utf8) == true else {
            throw Failure.staleObservation
        }
        guard AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, replacement as CFString) == .success else {
            throw Failure.operationUnknown
        }
    }

    private func sendKey(_ action: ComputerAction, in window: Window) throws {
        guard let key = action.key?.lowercased(), let code = Self.keys[key],
              let focused = Self.element(Self.attribute(window.application, kAXFocusedUIElementAttribute)),
              Self.sameElement(lastFocused, focused), !Self.isProtected(focused), Self.belongs(focused, to: window),
              let role = Self.attribute(focused, kAXRoleAttribute) as? String,
              role != "AXLink",
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw Failure.unsupportedControl
        }
        if key == "cmd+a" {
            guard Self.editableRoles.contains(role) else { throw Failure.unsupportedControl }
            down.flags = .maskCommand
            up.flags = .maskCommand
        } else if key == "shift+tab" {
            down.flags = .maskShift
            up.flags = .maskShift
        } else {
            down.flags = []
            up.flags = []
        }
        try requireUnchanged(window, focused: focused)
        down.postToPid(window.identity.pid)
        up.postToPid(window.identity.pid)
    }

    private func scroll(_ action: ComputerAction, in window: Window) throws {
        let dx = action.deltaX ?? 0
        let dy = action.deltaY ?? 0
        guard (-6...6).contains(dx), (-6...6).contains(dy), dx != 0 || dy != 0,
              let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                                  wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
            throw Failure.invalidAction
        }
        let observed: ObservedElement
        if action.elementID != nil || action.x != nil || action.y != nil {
            observed = try targetElement(action, in: window)
        } else {
            guard let scrollable = elements.values.first(where: { $0.description.role == kAXScrollAreaRole }) else {
                throw Failure.unsupportedControl
            }
            observed = scrollable
        }
        guard let rect = Self.frame(observed.ax) else { throw Failure.unsupportedControl }
        let visible = rect.intersection(window.frame)
        guard !visible.isNull, visible.width > 1, visible.height > 1 else { throw Failure.staleObservation }
        event.location = CGPoint(x: visible.midX, y: visible.midY)
        try requireUnchanged(window)
        event.postToPid(window.identity.pid)
    }

    private func targetElement(_ action: ComputerAction, in window: Window) throws -> ObservedElement {
        if let id = action.elementID {
            guard let target = elements[id],
                  target.menuKind != nil || Self.belongs(target.ax, to: window) else { throw Failure.staleObservation }
            return target
        }
        guard let x = action.x, let y = action.y, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw Failure.invalidAction
        }
        let point = CGPoint(x: min(window.frame.maxX - 0.5, window.frame.minX + x * window.frame.width),
                            y: min(window.frame.maxY - 0.5, window.frame.minY + y * window.frame.height))
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(window.application, Float(point.x), Float(point.y), &hit) == .success,
              let hit, Self.belongs(hit, to: window), !Self.isProtected(hit) else { throw Failure.staleObservation }
        var cursor: AXUIElement? = hit
        for _ in 0..<5 {
            guard let node = cursor, !CFEqual(node, window.ax), !Self.isProtected(node) else { break }
            if let matching = elements.values.first(where: { CFEqual($0.ax, node) }) { return matching }
            cursor = Self.element(Self.attribute(node, kAXParentAttribute))
        }
        throw Failure.unsupportedControl
    }

    private func requireUnchanged(_ expected: Window, focused: AXUIElement? = nil, background: Bool = false) throws {
        try Task.checkCancellation()
        try requireInteractiveSession()
        if !background { try requireNoNewInput() }
        let current = try window(in: expected.identity.appID, requiringForeground: !background)
        guard expected.matches(current) else { throw Failure.staleObservation }
        if background && NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.identity.pid {
            throw Failure.takeover
        }
        try requireSafeFocus(current)
        if let focused {
            guard let stillFocused = Self.element(Self.attribute(current.application, kAXFocusedUIElementAttribute)),
                  CFEqual(stillFocused, focused) else { throw Failure.staleObservation }
        }
    }

    private func capture(_ target: Window) async throws -> Data? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let choices = content.windows.filter { window in
            window.windowLayer == 0 && window.isOnScreen
                && window.owningApplication?.processID == target.identity.pid
                && window.owningApplication?.bundleIdentifier == target.identity.appID
                && Self.matches(window.frame, target.frame)
        }
        guard choices.count == 1, let window = choices.first else { return nil }
        let config = SCStreamConfiguration()
        let factor = min(1, 1_024 / max(1, window.frame.width, window.frame.height))
        config.width = max(1, Int(window.frame.width * factor))
        config.height = max(1, Int(window.frame.height * factor))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.capturesAudio = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try Task.checkCancellation()
        let bytes = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary
        CGImageDestinationAddImage(encoder, image, options)
        guard CGImageDestinationFinalize(encoder), bytes.length <= ComputerObservation.maximumImageBytes else { return nil }
        return bytes as Data
    }
}

private extension ComputerExecutor {
    struct Identity: Equatable {
        let appID: String
        let pid: pid_t
        let launch: Date
    }

    struct Window {
        let identity: Identity
        let application: AXUIElement
        let ax: AXUIElement
        let frame: CGRect

        @MainActor func matches(_ other: Self) -> Bool {
            identity == other.identity && CFEqual(ax, other.ax) && ComputerExecutor.matches(frame, other.frame)
        }
    }

    struct ObservedElement {
        let ax: AXUIElement
        let description: ComputerElement
        let frame: CGRect?
        let selection: NSRange?
        let selectionFingerprint: SHA256.Digest?
        var menuKind: MenuKind?

        @MainActor func stillMatches() -> Bool {
            guard let current = ComputerExecutor.describe(ax) else { return false }
            return current.description.role == description.role && current.description.label == description.label
                && current.description.value == description.value && current.frame == frame && current.selection == selection
                && current.selectionFingerprint == selectionFingerprint
        }
    }

    enum MenuKind: String, CaseIterable {
        case undo, save

        var shortcut: String { self == .undo ? "z" : "s" }
    }

    struct Scan {
        var elements: [ObservedElement] = []
        var containsProtectedElement = false
        var complete = true
    }

    enum Failure: LocalizedError {
        case accessibilityPermission, appNotAllowed, unavailable, staleObservation, protectedContent
        case locked, takeover, unsupportedControl, invalidAction, operationUnknown, backgroundUnsupported, pointerReview

        var errorDescription: String? {
            switch self {
            case .accessibilityPermission: "Allow Aides to use Accessibility in macOS Privacy & Security."
            case .appNotAllowed: "This app is outside the approved desktop task."
            case .unavailable: "Open the approved app in the active macOS session."
            case .staleObservation: "The approved window or control changed. Check it before starting a new run."
            case .protectedContent: "Protected input is active. Continue manually on the target Mac."
            case .locked: "Unlock the target Mac and make its desktop session active."
            case .takeover: "Local keyboard, pointer, or window activity interrupted the task."
            case .unsupportedControl: "The selected control does not expose the requested safe operation."
            case .invalidAction: "The desktop action is missing its scoped control or has invalid arguments."
            case .pointerReview: "Pointer actions require a recent image and confirmation on the target Mac."
            case .backgroundUnsupported: "This operation requires the approved app in the foreground. Continue manually on the target Mac."
            case .operationUnknown: "The app did not confirm the operation. Check the target before repeating it."
            }
        }
    }

    static let editableRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
    static let pressableRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXDisclosureTriangleRole,
        kAXMenuButtonRole, kAXTabGroupRole, "AXToggle"
    ]
    static let readableRoles: Set<String> = [
        kAXStaticTextRole, kAXHeadingRole, kAXSliderRole, kAXScrollAreaRole, kAXImageRole, kAXRowRole, "AXLink",
        kAXListRole, kAXCellRole, kAXMenuItemRole, kAXToolbarRole, kAXTabGroupRole
    ]
    static let keys: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "escape": 53, "tab": 48, "shift+tab": 48,
        "left": 123, "right": 124, "down": 125, "up": 126, "backspace": 51, "delete": 117,
        "space": 49, "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "cmd+a": 0
    ]

    static func isEligible(_ id: String) -> Bool {
        ComputerApp.isEligible(id) && id != Bundle.main.bundleIdentifier && !isSecurityApp(id)
    }

    static func isSecurityApp(_ id: String) -> Bool {
        let name = id.lowercased()
        return [
            "com.apple.loginwindow", "com.apple.screenlock", "com.apple.screensaver", "com.apple.securityagent",
            "com.apple.systempreferences", "com.apple.systemsettings", "com.apple.keychainaccess",
            "com.apple.passwords", "com.apple.terminal", "com.googlecode.iterm2", "com.apple.installer",
            "com.apple.activitymonitor", "com.apple.diskutility", "com.apple.scripteditor2",
            "com.apple.shortcuts", "com.apple.automator"
        ].contains(name) || ["password", "keychain", "securityagent", "authentication", "1password", "bitwarden", "keepass"]
            .contains(where: name.contains)
    }

    static func isProtected(_ node: AXUIElement) -> Bool {
        let role = (attribute(node, kAXRoleAttribute) as? String ?? "").lowercased()
        let subrole = (attribute(node, kAXSubroleAttribute) as? String ?? "").lowercased()
        let title = (attribute(node, kAXTitleAttribute) as? String ?? "").lowercased()
        let description = (attribute(node, kAXDescriptionAttribute) as? String ?? "").lowercased()
        let securityPrompt = ["password", "passcode", "one-time code", "verification code", "security key", "api key", "secret token"]
        return role.contains("secure") || subrole.contains("secure")
            || securityPrompt.contains(where: { title.contains($0) || description.contains($0) })
    }

    static func isWindowButton(_ node: AXUIElement) -> Bool {
        let buttons = [kAXCloseButtonSubrole, kAXMinimizeButtonSubrole, kAXZoomButtonSubrole, kAXFullScreenButtonSubrole]
        return buttons.contains(attribute(node, kAXSubroleAttribute) as? String ?? "")
    }

    static func describe(_ node: AXUIElement) -> ObservedElement? {
        guard let role = attribute(node, kAXRoleAttribute) as? String,
              !isWindowButton(node),
              editableRoles.contains(role) || pressableRoles.contains(role) || readableRoles.contains(role) else { return nil }
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
            .compactMap { text(attribute(node, $0)) }.first?.prefixText(160) ?? ""
        let value: String?
        if editableRoles.contains(role),
           let selected = text(attribute(node, kAXSelectedTextAttribute)), !selected.isEmpty {
            value = "Selected text: " + selected.prefixText(900)
        } else {
            value = text(attribute(node, kAXValueAttribute))?.prefixText(360)
        }
        guard !label.isEmpty || value != nil || editableRoles.contains(role) || role == kAXScrollAreaRole else { return nil }
        let selectedRange = editableRoles.contains(role) ? selection(node) : nil
        return ObservedElement(ax: node, description: ComputerElement(
            id: UUID().uuidString.lowercased(), role: role, label: label, value: value
        ), frame: frame(node), selection: selectedRange,
        selectionFingerprint: selectedRange.flatMap { fingerprint(node, range: $0) })
    }

    static func selection(_ node: AXUIElement) -> NSRange? {
        guard let value = attribute(node, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0, range.length >= 0, range.location <= Int.max - range.length else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    static func fingerprint(_ node: AXUIElement, range: NSRange) -> SHA256.Digest? {
        if range.length == 0 { return SHA256.hash(data: Data()) }
        guard range.length <= 16_384,
              let text = text(attribute(node, kAXSelectedTextAttribute)),
              text.utf8.count <= 65_536 else { return nil }
        return SHA256.hash(data: Data(text.utf8))
    }

    static func textEditMenuItems(in window: Window) -> [ObservedElement] {
        guard let menuBar = element(attribute(window.application, kAXMenuBarAttribute)) else { return [] }
        let deadline = ContinuousClock.now + .milliseconds(350)
        var matches: [MenuKind: [AXUIElement]] = [:]
        for topLevel in children(of: menuBar, limit: 16) {
            guard ContinuousClock.now < deadline else { return [] }
            for menu in children(of: topLevel, limit: 3) {
                guard ContinuousClock.now < deadline else { return [] }
                for node in children(of: menu, limit: 35) {
                    guard ContinuousClock.now < deadline else { return [] }
                    guard let shortcut = (attribute(node, kAXMenuItemCmdCharAttribute) as? String)?.lowercased(),
                          let kind = MenuKind.allCases.first(where: { $0.shortcut == shortcut }),
                          (attribute(node, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0,
                          attribute(node, kAXRoleAttribute) as? String == kAXMenuItemRole,
                          attribute(node, kAXEnabledAttribute) as? Bool == true else { continue }
                    var pid: pid_t = 0
                    guard AXUIElementGetPid(node, &pid) == .success, pid == window.identity.pid else { continue }
                    matches[kind, default: []].append(node)
                }
            }
        }
        return MenuKind.allCases.compactMap { kind in
            guard let candidates = matches[kind], candidates.count == 1,
                  let node = candidates.first, supports(node, kAXPressAction),
                  let label = text(attribute(node, kAXTitleAttribute)), !isProtected(node) else { return nil }
            return ObservedElement(ax: node, description: ComputerElement(
                id: UUID().uuidString.lowercased(), role: kAXMenuItemRole, label: "Menu: " + label.prefixText(150)
            ), frame: nil, selection: nil, selectionFingerprint: nil, menuKind: kind)
        }
    }

    static func children(of node: AXUIElement, limit: Int) -> [AXUIElement] {
        var count = 0
        guard AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &count) == .success,
              count > 0 else { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, min(count, limit), &values) == .success
        else { return [] }
        return values as? [AXUIElement] ?? []
    }

    static func sameElement(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): CFEqual(a, b)
        default: false
        }
    }

    static func belongs(_ node: AXUIElement, to window: Window) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(node, &pid) == .success, pid == window.identity.pid else { return false }
        if CFEqual(node, window.ax) { return true }
        guard let owner = element(attribute(node, kAXWindowAttribute)) else { return false }
        return CFEqual(owner, window.ax)
    }

    static func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success else { return nil }
        return value
    }

    static func text(_ value: CFTypeRef?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let attributed = value as? NSAttributedString, !attributed.string.isEmpty { return attributed.string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func frame(_ node: AXUIElement) -> CGRect? {
        guard let position = attribute(node, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(node, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    static func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 4 && abs(lhs.minY - rhs.minY) <= 4
            && abs(lhs.width - rhs.width) <= 4 && abs(lhs.height - rhs.height) <= 4
    }

    static func settable(_ node: AXUIElement, _ key: String) -> Bool {
        var answer = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(node, key as CFString, &answer) == .success && answer.boolValue
    }

    static func supports(_ node: AXUIElement, _ action: String) -> Bool {
        var actions: CFArray?
        return AXUIElementCopyActionNames(node, &actions) == .success && (actions as? [String])?.contains(action) == true
    }
}

private extension String {
    func prefixText(_ maximum: Int) -> String {
        var bytes = 0
        return String(unicodeScalars.prefix(while: { scalar in
            bytes += scalar.utf8.count
            return bytes <= maximum
        }))
    }
}
