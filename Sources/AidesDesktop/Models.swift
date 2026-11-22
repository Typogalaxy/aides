import Foundation

struct DesktopState: Decodable, Sendable {
    var revision = -1
    var threads: [Conversation] = []
    var projects: [Project] = []
    var tasks: [WorkerTask] = []
    var schedules: [WorkSchedule] = []
    var models: [ModelConfiguration] = []
    var devices: [PairedDevice] = []
    var settings = ServerSettings()
    var metrics = ServerMetrics()
}

struct Conversation: Decodable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let role: String
    let projectID: UUID?
    let messages: [ChatMessage]
    let archivedAt: Date?
    let report: String?

    var icon: String {
        switch role {
        case "secretary": "sparkles"
        case "area": "square.grid.2x2"
        case "project": "folder"
        default: "bubble.left"
        }
    }
}

struct ChatMessage: Decodable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let role: String
    let createdAt: Date

    var isUser: Bool { role == "user" }
}

struct Project: Decodable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let directory: String?
    let createdAt: Date
}

struct WorkerTask: Decodable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let instruction: String?
    let threadID: UUID?
    let projectID: UUID?
    let modelID: UUID?
    let status: String
    let scheduledAt: Date?
    let result: String?
    let error: String?
    let createdAt: Date
    let updatedAt: Date

    var isFinished: Bool { ["completed", "failed", "cancelled"].contains(status) }
    var statusLabel: String {
        switch status {
        case "waitingApproval": "Awaiting approval"
        case "waiting": "Waiting"
        default: status.capitalized
        }
    }
}

struct WorkSchedule: Decodable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let kind: String
    let repeatRule: String
    let timeZone: String
    let nextRun: Date?
    let paused: Bool
}

struct ModelConfiguration: Decodable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let kind: String
    let endpoint: String
    let model: String
    let hasCredential: Bool

    var kindLabel: String { ModelKind(rawValue: kind)?.label ?? kind }
}

enum ModelKind: String, CaseIterable, Identifiable, Sendable {
    case ollama, openAI, claude, codex, claudeCode, mock

    var id: Self { self }

    var label: String {
        switch self {
        case .ollama: "Ollama (local)"
        case .openAI: "OpenAI API"
        case .claude: "Claude API"
        case .codex: "Codex CLI"
        case .claudeCode: "Claude Code CLI"
        case .mock: "Mock (development)"
        }
    }

    var suggestedEndpoint: String {
        switch self {
        case .ollama: "http://127.0.0.1:11434"
        case .openAI: "https://api.openai.com/v1"
        case .claude: "https://api.anthropic.com/v1"
        case .codex: "codex"
        case .claudeCode: "claude"
        case .mock: ""
        }
    }

    var usesAPIKey: Bool { self == .openAI || self == .claude }
}

struct PairedDevice: Decodable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let createdAt: Date
}

struct ServerSettings: Decodable, Sendable {
    var defaultModelID: UUID?
    var preference = ""
}

struct ServerMetrics: Decodable, Sendable {
    var requests = 0
    var inputTokens = 0
    var outputTokens = 0
    var storageBytes = 0
    var networkBytes = 0
    var memoryBytes: Int? = nil
}

struct MemoryRecord: Decodable, Identifiable, Sendable {
    let id: UUID
    let key: String
    let value: String
    let scope: String
    let source: String
    let sensitivity: String
    let updatedAt: Date
}
