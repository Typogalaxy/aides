import Foundation

extension ModelClient {
    func generateOllama(_ request: ModelRequest) async throws -> ModelOutput {
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
        let response = try await post(
            endpoint,
            payload: OllamaInput(model: localName, messages: messages, options: .init(numPredict: request.maxOutputTokens)),
            expecting: OllamaOutput.self
        )

        guard response.remoteModel == nil, response.remoteHost == nil else {
            throw ModelExecutionError.unexpectedResponse
        }
        guard response.done, response.message.role == "assistant", !response.message.content.isEmpty else {
            throw ModelExecutionError.unexpectedResponse
        }
        return ModelOutput(
            text: response.message.content,
            inputTokens: response.inputTokens,
            outputTokens: response.outputTokens
        )
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
    let stream = false
    let options: Options
}

private struct OllamaOutput: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String
    }

    let message: Message
    let done: Bool
    let remoteModel: String?
    let remoteHost: String?
    let inputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case message, done
        case remoteModel = "remote_model"
        case remoteHost = "remote_host"
        case inputTokens = "prompt_eval_count"
        case outputTokens = "eval_count"
    }
}
