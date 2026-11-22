import Foundation

public struct ModelClient: Sendable {
    typealias Exchange = @Sendable (URLRequest) async throws -> HTTPPayload

    let exchange: Exchange

    public init() {
        self.init(exchange: ModelTransport.exchange)
    }

    init(exchange: @escaping Exchange) {
        self.exchange = exchange
    }

    public func generate(_ request: ModelRequest) async throws -> ModelOutput {
        try Task.checkCancellation()
        try request.validate()
        return switch request.provider {
        case .stub:
            stubResponse(request)
        case .ollama:
            try await generateOllama(request)
        case .openAI:
            try await generateOpenAI(request)
        case .anthropic:
            try await generateAnthropic(request)
        }
    }

    private func stubResponse(_ request: ModelRequest) -> ModelOutput {
        let input = request.messages.last(where: { $0.role == .user })?.text ?? ""
        let text = String("Test model received: \(input)".prefix(request.maxOutputTokens))
        return ModelOutput(text: text, inputTokens: nil, outputTokens: nil)
    }

}
