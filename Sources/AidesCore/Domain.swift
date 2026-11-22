import Foundation

public enum ConversationRole: String, Codable, Sendable {
    case secretary, area, project, task
}

public enum MessageRole: String, Codable, Sendable {
    case user, assistant, system
}

public struct Message: Codable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let role: MessageRole
    public let createdAt: Date

    public let scheduleSuggestion: ScheduleSuggestion?
    public let toolkitSuggestion: ToolkitSuggestion?

    public init(
        _ text: String, role: MessageRole, now: Date = .now,
        scheduleSuggestion: ScheduleSuggestion? = nil, toolkitSuggestion: ToolkitSuggestion? = nil
    ) {
        id = UUID()
        self.text = text
        self.role = role
        createdAt = now
        self.scheduleSuggestion = scheduleSuggestion
        self.toolkitSuggestion = toolkitSuggestion
    }
}

public struct Conversation: Codable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let role: ConversationRole
    public let projectID: UUID?
    public var messages: [Message]
    public var archivedAt: Date?
    public var report: String?

    public init(title: String, role: ConversationRole, projectID: UUID? = nil) {
        id = UUID()
        self.title = title
        self.role = role
        self.projectID = projectID
        messages = []
    }
}

public struct Project: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let directory: String?
    public let createdAt: Date
    public var watching: Bool?

    public init(name: String, directory: String?, now: Date = .now) {
        id = UUID()
        self.name = name
        self.directory = directory
        createdAt = now
    }
}

public enum WorkStatus: String, Codable, Sendable {
    case queued, scheduled, running, waitingApproval, waiting, completed, failed, cancelled

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

public enum WorkKind: String, Codable, Sendable {
    case conversation, analysis, reminder, review, codeProposal
    // Retain the serialized kind for historical records from older builds.
    case retiredMail = "mail"
}

public struct WorkItem: Codable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let threadID: UUID?
    public let projectID: UUID?
    public let modelID: UUID?
    public let kind: WorkKind
    public let parentID: UUID?
    public let scheduleID: UUID?
    public let instruction: String
    public var approvedCloud: Bool
    public var sharedMemories: [MemoryRecord]?
    public var toolkitGrant: ToolkitWorkGrant?
    public var toolkitSuggestion: ToolkitSuggestion?
    public var toolkitSuggestionMessageID: UUID?
    public var status: WorkStatus
    public var scheduledAt: Date?
    public var result: String?
    public var error: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        title: String, instruction: String? = nil, threadID: UUID? = nil, projectID: UUID? = nil,
        modelID: UUID? = nil, kind: WorkKind = .analysis, parentID: UUID? = nil,
        scheduleID: UUID? = nil, approvedCloud: Bool = false, scheduledAt: Date? = nil, now: Date = .now
    ) {
        id = UUID()
        self.title = title
        self.instruction = instruction ?? title
        self.threadID = threadID
        self.projectID = projectID
        self.modelID = modelID
        self.kind = kind
        self.parentID = parentID
        self.scheduleID = scheduleID
        self.approvedCloud = approvedCloud
        self.scheduledAt = scheduledAt
        status = scheduledAt.map { $0 > now } == true ? .scheduled : .queued
        createdAt = now
        updatedAt = now
    }
}

public enum ProviderKind: String, Codable, Sendable {
    case ollama, openAI, claude, codex, claudeCode, mock

    public var isLocal: Bool {
        self == .ollama || self == .mock
    }

    public var needsAPIKey: Bool {
        self == .openAI || self == .claude
    }
}

public struct ModelProfile: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let kind: ProviderKind
    public let endpoint: String
    public let model: String
    public var hasCredential: Bool

    public init(name: String, kind: ProviderKind, endpoint: String, model: String, hasCredential: Bool = false) {
        id = UUID()
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.model = model
        self.hasCredential = hasCredential
    }
}

public struct PairedDevice: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let createdAt: Date

    public init(name: String, now: Date = .now) {
        id = UUID()
        self.name = name
        createdAt = now
    }
}

public struct PreferenceSettings: Codable, Sendable {
    public var defaultModelID: UUID?
    public var reviewModelID: UUID?
    public var preference: String = ""
    public var preferenceRevision: Int = 0

    public init() {}
}

public struct UsageMetrics: Codable, Sendable {
    public var requests: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var storageBytes: Int = 0
    public var networkBytes: Int = 0
    public var processMemoryBytes: Int = 0

    public init() {}
}

public struct AppState: Codable, Sendable {
    public var revision: Int = 0
    public var threads: [Conversation] = [
        Conversation(title: "Secretary", role: .secretary)
    ]
    public var projects: [Project] = []
    public var tasks: [WorkItem] = []
    public var models: [ModelProfile] = []
    public var devices: [PairedDevice] = []
    public var settings = PreferenceSettings()
    public var metrics = UsageMetrics()
    public var schedules: [WorkSchedule] = []

    public init() {}
}
