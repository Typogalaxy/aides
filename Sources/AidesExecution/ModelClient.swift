import Foundation

public struct ModelClient: Sendable {
    typealias Exchange = @Sendable (URLRequest) async throws -> HTTPPayload

    typealias LineExchange = @Sendable (URLRequest, @escaping @Sendable (Data) async throws -> Void) async throws -> Int

    let exchange: Exchange
    let exchangeLines: LineExchange

    public init() {
        self.init(exchange: ModelTransport.exchange)
    }

    init(exchange: @escaping Exchange) {
        self.init(exchange: exchange, exchangeLines: ModelTransport.exchangeLines)
    }

    init(exchange: @escaping Exchange, exchangeLines: @escaping LineExchange) {
        self.exchange = exchange
        self.exchangeLines = exchangeLines
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

    /// Delivers visible text chunks for Ollama. Other providers retain their buffered response.
    public func generateStreaming(
        _ request: ModelRequest, onText: @escaping @Sendable (String) async -> Void
    ) async throws -> ModelOutput {
        try Task.checkCancellation()
        try request.validate()
        switch request.provider {
        case .ollama:
            return try await generateOllamaStream(request, onText: onText)
        default:
            return try await generate(request)
        }
    }

    private func stubResponse(_ request: ModelRequest) -> ModelOutput {
        let input = request.messages.last(where: { $0.role == .user })?.text ?? ""
        let text = String("Test model received: \(input)".prefix(request.maxOutputTokens))
        return ModelOutput(text: text, inputTokens: nil, outputTokens: nil)
    }

}
