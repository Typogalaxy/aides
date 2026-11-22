import Foundation

public enum ModelProvider: String, Codable, Sendable {
    case stub
    case ollama
    case openAI
    case anthropic

    public var isLocal: Bool {
        self == .stub || self == .ollama
    }
}

public struct ModelMessage: Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public struct ModelRequest: Sendable {
    public let provider: ModelProvider
    public let endpoint: URL
    public let model: String
    public let apiKey: String?
    public let system: String?
    public let messages: [ModelMessage]
    public let maxOutputTokens: Int

    public init(
        provider: ModelProvider,
        endpoint: URL,
        model: String,
        apiKey: String? = nil,
        system: String? = nil,
        messages: [ModelMessage],
        maxOutputTokens: Int = 2_048
    ) {
        self.provider = provider
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.system = system
        self.messages = messages
        self.maxOutputTokens = maxOutputTokens
    }

    func validate() throws {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.utf8.count <= 256,
              !messages.isEmpty,
              (1...131_072).contains(maxOutputTokens) else {
            throw ModelExecutionError.invalidConfiguration
        }

        // Bound allocation before encoding, including transcripts loaded from disk.
        var remaining = 1_048_576 - (system?.utf8.count ?? 0)
        guard remaining >= 0, messages.count <= 1_024 else {
            throw ModelExecutionError.inputLimit
        }
        for message in messages {
            remaining -= message.text.utf8.count
            guard remaining >= 0 else { throw ModelExecutionError.inputLimit }
        }
    }

    func checkedAPIKey() throws -> String {
        guard let apiKey,
              !apiKey.isEmpty,
              apiKey.utf8.count <= 4_096,
              apiKey.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw ModelExecutionError.invalidConfiguration
        }
        return apiKey
    }
}

public struct ModelOutput: Sendable {
    public let text: String
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(text: String, inputTokens: Int?, outputTokens: Int?) {
        self.text = text
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum ModelExecutionError: Error, Sendable, LocalizedError {
    case invalidConfiguration
    case unauthorized
    case rateLimited
    case unavailable
    case unexpectedResponse
    case rejected
    case inputLimit
    case outputLimit

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The model configuration is invalid."
        case .unauthorized:
            "The model provider rejected authentication."
        case .rateLimited:
            "The model provider's usage limit was reached."
        case .unavailable:
            "The model provider is unavailable. Try again later."
        case .unexpectedResponse:
            "The model provider returned an unexpected response."
        case .rejected:
            "The model provider rejected the request."
        case .inputLimit:
            "The model input exceeds the request size limit."
        case .outputLimit:
            "The model output exceeds the response size limit."
        }
    }
}
