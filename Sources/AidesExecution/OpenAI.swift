import Foundation

extension ModelClient {
    func generateOpenAI(_ request: ModelRequest) async throws -> ModelOutput {
        let endpoint = try request.modelEndpoint(
            route: "/v1/responses",
            acceptedBases: ["", "/v1"],
            officialHost: "api.openai.com"
        )
        let (response, networkBytes) = try await post(
            endpoint,
            payload: OpenAIInput(
                model: request.model,
                instructions: request.system,
                input: request.messages.map(WireMessage.init),
                maxOutputTokens: request.maxOutputTokens
            ),
            headers: ["Authorization": "Bearer " + (try request.checkedAPIKey())],
            expecting: OpenAIOutput.self
        )

        if response.status == "incomplete", response.incompleteDetails?.reason == "max_output_tokens" {
            throw ModelExecutionError.outputLimit
        }
        guard response.status == "completed" else { throw ModelExecutionError.rejected }

        let text = response.output
            .filter { $0.type == "message" && $0.role == "assistant" }
            .flatMap { $0.content ?? [] }
            .compactMap { content in
                switch content.type {
                case "output_text": content.text
                case "refusal": content.refusal
                default: nil
                }
            }
            .joined(separator: "\n")

        guard !text.isEmpty else { throw ModelExecutionError.unexpectedResponse }
        return ModelOutput(
            text: text,
            inputTokens: response.usage?.inputTokens,
            outputTokens: response.usage?.outputTokens,
            networkBytes: networkBytes
        )
    }
}

private struct OpenAIInput: Encodable {
    let model: String
    let instructions: String?
    let input: [WireMessage]
    let maxOutputTokens: Int
    let store = false

    enum CodingKeys: String, CodingKey {
        case model, instructions, input, store
        case maxOutputTokens = "max_output_tokens"
    }
}

private struct OpenAIOutput: Decodable {
    struct Item: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
            let refusal: String?
        }

        let type: String
        let role: String?
        let content: [Content]?
    }

    struct IncompleteDetails: Decodable {
        let reason: String?
    }

    struct Usage: Decodable {
        let inputTokens: Int
        let outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    let status: String
    let incompleteDetails: IncompleteDetails?
    let output: [Item]
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case status, output, usage
        case incompleteDetails = "incomplete_details"
    }
}
