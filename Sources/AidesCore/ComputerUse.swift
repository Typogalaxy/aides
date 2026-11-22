import Foundation

public struct ComputerApp: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public static func isEligible(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...180).contains(bundleID.utf8.count), parts.count >= 2, parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || [45, 95].contains($0) }
        }) else { return false }
        let denied = [
            "com.apple.systempreferences", "com.apple.systemsettings", "com.apple.securityagent",
            "com.apple.keychainaccess", "com.apple.passwords", "com.apple.loginwindow",
            "com.apple.terminal", "com.apple.scripteditor", "com.googlecode.iterm2",
            "com.openai.chat", "org.typogalaxy.aides"
        ]
        return !denied.contains(lower) &&
            !parts.contains { $0.contains("1password") || $0.contains("bitwarden") || $0.contains("keepass") || $0.contains("lastpass") }
    }
}

public enum ComputerActionKind: String, Codable, Sendable {
    case observe, activate, click, drag, movePointer, typeText, key, scroll, finish, handoff
}

public enum ComputerMouseButton: String, Codable, Sendable {
    case left, right
}

public struct ComputerAction: Codable, Equatable, Sendable {
    public let kind: ComputerActionKind
    public let appID: String?
    public let elementID: String?
    public let text: String?
    public let key: String?
    public let x: Double?
    public let y: Double?
    public let deltaX: Int?
    public let deltaY: Int?
    public let button: ComputerMouseButton?
    public let clickCount: Int?
    public let endX: Double?
    public let endY: Double?

    public init(
        kind: ComputerActionKind, appID: String? = nil, elementID: String? = nil,
        text: String? = nil, key: String? = nil, x: Double? = nil, y: Double? = nil,
        deltaX: Int? = nil, deltaY: Int? = nil, button: ComputerMouseButton? = nil,
        clickCount: Int? = nil, endX: Double? = nil, endY: Double? = nil
    ) {
        self.kind = kind
        self.appID = appID
        self.elementID = elementID
        self.text = text
        self.key = key
        self.x = x
        self.y = y
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.button = button
        self.clickCount = clickCount
        self.endX = endX
        self.endY = endY
    }

    public static let keys: Set<String> = [
        "Tab", "Shift+Tab", "Return", "Escape", "Space", "Up", "Down", "Left", "Right",
        "Backspace", "PageUp", "PageDown", "Home", "End", "Cmd+A"
    ]

    public func isValid(allowedAppIDs: [String], observation: ComputerObservation? = nil) -> Bool {
        if let appID, !allowedAppIDs.contains(appID) { return false }
        let isTerminal = kind == .finish || kind == .handoff
        if isTerminal != (appID == nil) { return false }
        if let elementID {
            guard (1...64).contains(elementID.utf8.count),
                  observation?.elements.contains(where: { $0.id == elementID }) ?? true else { return false }
        }
        if let text {
            guard (1...(isTerminal ? 2_000 : 4_096)).contains(text.utf8.count), !text.utf8.contains(0) else { return false }
        }
        let hasPosition = x != nil || y != nil
        if hasPosition {
            guard let x, let y, (0...1).contains(x), (0...1).contains(y) else { return false }
        }
        let hasEnd = endX != nil || endY != nil
        if hasEnd {
            guard kind == .drag, let endX, let endY, (0...1).contains(endX), (0...1).contains(endY),
                  endX != x || endY != y else { return false }
        }
        if button != nil || clickCount != nil {
            guard kind == .click, elementID == nil, hasPosition,
                  (1...2).contains(clickCount ?? 1), button != .right || (clickCount ?? 1) == 1 else { return false }
        }
        let hasScroll = deltaX != nil || deltaY != nil
        if hasScroll {
            guard (deltaX ?? 0) != 0 || (deltaY ?? 0) != 0,
                  (-6...6).contains(deltaX ?? 0), (-6...6).contains(deltaY ?? 0) else { return false }
        }
        if let observation, !isTerminal, kind != .observe, kind != .activate, appID != observation.appID { return false }
        switch kind {
        case .observe, .activate:
            return elementID == nil && text == nil && key == nil && !hasPosition && !hasScroll
        case .click:
            return (elementID != nil) != hasPosition && text == nil && key == nil && !hasScroll
        case .drag, .movePointer:
            return hasPosition && hasEnd == (kind == .drag) && elementID == nil && text == nil && key == nil && !hasScroll
        case .typeText:
            return text != nil && elementID != nil && key == nil && !hasPosition && !hasScroll
        case .key:
            return key.map(Self.keys.contains) == true && elementID == nil && text == nil && !hasPosition && !hasScroll
        case .scroll:
            return hasScroll && elementID == nil && text == nil && key == nil && !hasPosition
        case .finish, .handoff:
            return text != nil && elementID == nil && key == nil && !hasPosition && !hasScroll
        }
    }

    public var supportsBackground: Bool {
        switch kind {
        case .observe, .typeText, .finish, .handoff: true
        case .click: elementID != nil
        case .activate, .key, .scroll, .drag, .movePointer: false
        }
    }

    public func needsReview(observation: ComputerObservation, allowRoutineActions: Bool) -> Bool {
        if kind == .observe || kind == .activate { return false }
        guard allowRoutineActions, appID == "com.apple.TextEdit" else { return true }
        if kind == .scroll { return false }
        if kind == .typeText,
           let element = observation.elements.first(where: { $0.id == elementID }),
           element.role == "AXTextArea" {
            return false
        }
        return kind != .key || !["Left", "Right", "Up", "Down", "PageUp", "PageDown", "Home", "End"].contains(key ?? "")
    }
}

public struct ComputerElement: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let label: String
    public let value: String?

    public init(id: String, role: String, label: String, value: String? = nil) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
    }
}

public struct ComputerObservation: Codable, Equatable, Sendable {
    public let appID: String
    public let windowTitle: String
    public let elements: [ComputerElement]
    public let screenshot: Data?
    public let notice: String?
    public let isBackground: Bool?

    public init(appID: String, windowTitle: String, elements: [ComputerElement], screenshot: Data? = nil, notice: String? = nil, isBackground: Bool? = nil) {
        self.appID = appID
        self.windowTitle = windowTitle
        self.elements = elements
        self.screenshot = screenshot
        self.notice = notice
        self.isBackground = isBackground
    }

    public static let maximumImageBytes = 384 * 1_024

    public func isValid(allowImages: Bool, expectedAppID: String?) -> Bool {
        guard appID == expectedAppID, ComputerApp.isEligible(appID), windowTitle.utf8.count <= 1_024,
              (notice?.utf8.count ?? 0) <= 512, elements.count <= 120,
              Set(elements.map(\.id)).count == elements.count else { return false }
        var size = 0
        for element in elements {
            guard (1...64).contains(element.id.utf8.count), element.role.utf8.count <= 64,
                  element.label.utf8.count <= 512, (element.value?.utf8.count ?? 0) <= 4_096 else { return false }
            size += element.label.utf8.count + (element.value?.utf8.count ?? 0)
        }
        guard size <= 24_576 else { return false }
        guard let screenshot else { return true }
        return allowImages && screenshot.count <= Self.maximumImageBytes &&
            screenshot.starts(with: [0xff, 0xd8, 0xff])
    }
}

public enum ComputerRunStatus: String, Codable, Sendable {
    case awaitingPermission, queued, running, awaitingApproval, paused, completed, stopped, interrupted, failed

    public var isTerminal: Bool {
        self == .completed || self == .stopped || self == .failed
    }

    public var isActive: Bool {
        self == .queued || self == .running || self == .awaitingApproval
    }
}

public struct ComputerStep: Codable, Identifiable, Sendable {
    public var id: Int { number }
    public let number: Int
    public let kind: ComputerActionKind
    public let appID: String?
    public let date: Date

    public init(number: Int, kind: ComputerActionKind, appID: String?, date: Date = .now) {
        self.number = number
        self.kind = kind
        self.appID = appID
        self.date = date
    }
}

public struct ComputerReviewContext: Codable, Sendable {
    public let windowTitle: String
    public let label: String?
    public let role: String?

    public init(windowTitle: String, label: String?, role: String?) {
        self.windowTitle = windowTitle
        self.label = label
        self.role = role
    }
}

public struct ComputerRun: Codable, Identifiable, Sendable {
    public let id: UUID
    public let deviceID: UUID
    public let requestedByDeviceID: UUID
    public let appIDs: [String]
    public let instruction: String
    public let modelID: UUID
    public let threadID: UUID?
    public let includeImages: Bool
    public let createdAt: Date
    public var updatedAt: Date
    public var status: ComputerRunStatus
    public var steps: [ComputerStep]
    public var result: String?
    public var message: String?
    public var pendingAction: ComputerAction?
    public var pendingReview: ComputerReviewContext?
    public var pendingCommandID: UUID?
    public var allowRoutineActions: Bool?
    public var allowBackground: Bool?
    public var requiresFreshApproval: Bool?

    public init(
        id: UUID, deviceID: UUID, requestedByDeviceID: UUID, appIDs: [String],
        instruction: String, modelID: UUID, includeImages: Bool, threadID: UUID? = nil, now: Date = .now
    ) {
        self.id = id
        self.deviceID = deviceID
        self.requestedByDeviceID = requestedByDeviceID
        self.appIDs = appIDs
        self.instruction = instruction
        self.modelID = modelID
        self.threadID = threadID
        self.includeImages = includeImages
        createdAt = now
        updatedAt = now
        status = .awaitingPermission
        steps = []
    }
}

public struct ComputerCommand: Codable, Identifiable, Sendable {
    public let id: UUID
    public let runID: UUID
    public let appIDs: [String]
    public let includeImages: Bool
    public let action: ComputerAction
    public let allowBackground: Bool

    public init(
        id: UUID, runID: UUID, appIDs: [String], includeImages: Bool,
        action: ComputerAction, allowBackground: Bool = false
    ) {
        self.id = id
        self.runID = runID
        self.appIDs = appIDs
        self.includeImages = includeImages
        self.action = action
        self.allowBackground = allowBackground
    }
}

public struct ComputerClaim: Codable, Sendable {
    public let command: ComputerCommand?

    public init(command: ComputerCommand?) {
        self.command = command
    }
}
