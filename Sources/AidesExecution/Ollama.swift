import Foundation

extension ModelClient {
    func generateOllama(_ request: ModelRequest, requiresJSONObject: Bool = false) async throws -> ModelOutput {
        let (endpoint, payload) = try ollamaPOST(request, stream: false, requiresJSONObject: requiresJSONObject)
        let (response, networkBytes) = try await post(
            endpoint,
            payload: payload,
            expecting: OllamaOutput.self
        )

        guard response.remoteModel == nil, response.remoteHost == nil else {
            throw ModelExecutionError.unexpectedResponse
        }
        if requiresJSONObject, response.doneReason == "length" { throw ModelExecutionError.outputLimit }
        guard response.done, response.message.role == "assistant", !response.message.content.isEmpty else {
            throw ModelExecutionError.unexpectedResponse
        }
        return ModelOutput(
            text: response.message.content,
            inputTokens: response.inputTokens,
            outputTokens: response.outputTokens,
            networkBytes: networkBytes
        )
    }

    func generateOllamaStream(
        _ request: ModelRequest, onText: @escaping @Sendable (String) async -> Void
    ) async throws -> ModelOutput {
        let (endpoint, payload) = try ollamaPOST(request, stream: true, requiresJSONObject: false)
        let http = try modelPOST(endpoint, payload: payload, headers: [:], accept: "application/x-ndjson")
        let stream = OllamaStream()
        let received = try await exchangeLines(http) { line in
            let text = try await stream.receive(line)
            if !text.isEmpty {
                await onText(text)
            }
        }
        return try await stream.finish(networkBytes: (http.httpBody?.count ?? 0) + received)
    }

    private func ollamaPOST(
        _ request: ModelRequest, stream: Bool, requiresJSONObject: Bool
    ) throws -> (URL, OllamaInput) {
        guard request.apiKey == nil else { throw ModelExecutionError.invalidConfiguration }
        let endpoint = try request.modelEndpoint(route: "/api/chat", acceptedBases: ["", "/api"])
        let name = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercase = name.lowercased()
        guard !lowercase.hasSuffix(":cloud"), !lowercase.hasSuffix("-cloud") else {
            throw ModelExecutionError.invalidConfiguration
        }

        // Current Ollama supports an explicit source suffix. Require local inference
        // even when the model name happens to resolve to an upstream model alias.
        let localName = lowercase.hasSuffix(":local") ? name : name + ":local"
        var messages = request.messages.map(WireMessage.init)
        if let system = request.system, !system.isEmpty {
            messages.insert(WireMessage(role: "system", content: system), at: 0)
        }
        return (endpoint, OllamaInput(
            model: localName, messages: messages, stream: stream, options: .init(numPredict: request.maxOutputTokens),
            format: requiresJSONObject ? "json" : nil
        ))
    }
}

private struct OllamaInput: Encodable {
    struct Options: Encodable {
        let numPredict: Int

        enum CodingKeys: String, CodingKey {
            case numPredict = "num_predict"
        }
    }

    let model: String
    let messages: [WireMessage]
    let stream: Bool
    let options: Options
    let format: String?
}

private struct OllamaOutput: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String
    }

    let message: Message
    let done: Bool
    let doneReason: String?
    let remoteModel: String?
    let remoteHost: String?
    let inputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case message, done
        case doneReason = "done_reason"
        case remoteModel = "remote_model"
        case remoteHost = "remote_host"
        case inputTokens = "prompt_eval_count"
        case outputTokens = "eval_count"
    }
}

private actor OllamaStream {
    private var text = ""
    private var terminal: OllamaOutput?

    func receive(_ line: Data) throws -> String {
        guard terminal == nil, let chunk = try? JSONDecoder().decode(OllamaOutput.self, from: line),
              chunk.remoteModel == nil, chunk.remoteHost == nil, chunk.message.role == "assistant" else {
            throw ModelExecutionError.unexpectedResponse
        }
        let delta = chunk.message.content
        text += delta
        if chunk.done { terminal = chunk }
        return delta
    }

    func finish(networkBytes: Int) throws -> ModelOutput {
        guard let terminal, !text.isEmpty else { throw ModelExecutionError.unexpectedResponse }
        return ModelOutput(
            text: text, inputTokens: terminal.inputTokens, outputTokens: terminal.outputTokens,
            networkBytes: networkBytes
        )
    }
}
