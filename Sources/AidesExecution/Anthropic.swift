import Foundation

extension ModelClient {
    func generateAnthropic(_ request: ModelRequest) async throws -> ModelOutput {
        let endpoint = try request.modelEndpoint(
            route: "/v1/messages",
            acceptedBases: ["", "/v1"],
            officialHost: "api.anthropic.com"
        )
        let response = try await post(
            endpoint,
            payload: AnthropicInput(
                model: request.model,
                system: request.system,
                messages: request.messages.map(WireMessage.init),
                maxTokens: request.maxOutputTokens
            ),
            headers: [
                "x-api-key": try request.checkedAPIKey(),
                "anthropic-version": "2023-06-01"
            ],
            expecting: AnthropicOutput.self
        )

        switch response.stopReason {
        case "max_tokens":
            throw ModelExecutionError.outputLimit
        case "model_context_window_exceeded":
            throw ModelExecutionError.inputLimit
        case "end_turn", "stop_sequence", "refusal":
            break
        default:
            throw ModelExecutionError.unexpectedResponse
        }

        let text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
        guard response.role == "assistant", !text.isEmpty else {
            throw ModelExecutionError.unexpectedResponse
        }
        return ModelOutput(
            text: text,
            inputTokens: response.usage?.totalInputTokens,
            outputTokens: response.usage?.outputTokens
        )
    }
}

private struct AnthropicInput: Encodable {
    let model: String
    let system: String?
    let messages: [WireMessage]
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, system, messages
        case maxTokens = "max_tokens"
    }
}

private struct AnthropicOutput: Decodable {
    struct Block: Decodable {
        let type: String
        let text: String?
    }

    struct Usage: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?

        var totalInputTokens: Int {
            let cached = (cacheCreationInputTokens ?? 0).addingReportingOverflow(cacheReadInputTokens ?? 0)
            let total = inputTokens.addingReportingOverflow(cached.partialValue)
            return cached.overflow || total.overflow ? inputTokens : total.partialValue
        }

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }

    let role: String
    let content: [Block]
    let stopReason: String?
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case role, content, usage
        case stopReason = "stop_reason"
    }
}
