import AidesCore

extension Conversation {
    var icon: String {
        switch role {
        case .secretary: "sparkles"
        case .area: "square.grid.2x2"
        case .project: "folder"
        case .task: "bubble.left"
        }
    }
}

extension Message {
    var isUser: Bool { role == .user }
}

extension WorkItem {
    var isFinished: Bool { status.isTerminal }

    var statusLabel: String {
        switch status {
        case .waitingApproval: "Awaiting approval"
        default: status.rawValue.capitalized
        }
    }
}

extension ModelProfile {
    var kindLabel: String { kind.label }
}

extension ProviderKind {
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
        default: ""
        }
    }
}
