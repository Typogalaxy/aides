import Foundation
import Testing
@testable import AidesExecution

struct ModelClientTests {
    @Test func stubCompletesWithoutHTTP() async throws {
        let client = ModelClient { _ in throw TestError.unexpectedRequest }
        let output = try await client.generate(request(.stub, "http://127.0.0.1", maxOutputTokens: 8))

        #expect(output.text == "Test mod")
        #expect(output.inputTokens == nil)
    }

    @Test func ollamaAlwaysRequestsLocalInference() async throws {
        let client = ModelClient { outbound in
            #expect(outbound.url?.absoluteString == "http://127.0.0.1:11434/api/chat")
            #expect(outbound.value(forHTTPHeaderField: "Authorization") == nil)

            let body = try Self.body(outbound)
            #expect(body["model"] as? String == "example:8b:local")
            #expect(body["stream"] as? Bool == false)
            #expect((body["options"] as? [String: Int])?["num_predict"] == 40)
            #expect((body["messages"] as? [[String: String]])?.first?["role"] == "system")
            return fixture("""
                {"message":{"role":"assistant","content":"Local answer","thinking":"hidden"},
                 "done":true,"prompt_eval_count":11,"eval_count":6}
                """)
        }

        let output = try await client.generate(request(
            .ollama, "http://localhost:11434/api/", model: "example:8b", maxOutputTokens: 40
        ))

        #expect(output.text == "Local answer")
        #expect(output.inputTokens == 11)
        #expect(output.outputTokens == 6)
    }

    @Test func cloudOllamaAliasesAreRejected() async {
        let client = ModelClient { _ in throw TestError.unexpectedRequest }

        await #expect(throws: ModelExecutionError.invalidConfiguration) {
            try await client.generate(request(.ollama, "http://127.0.0.1:11434", model: "large:cloud"))
        }
    }

    @Test func openAIUsesStatelessResponses() async throws {
        let client = ModelClient { outbound in
            #expect(outbound.url?.absoluteString == "https://api.openai.com/v1/responses")
            #expect(outbound.value(forHTTPHeaderField: "Authorization") == "Bearer example-key")

            let body = try Self.body(outbound)
            #expect(body["instructions"] as? String == "Project guidelines")
            #expect(body["store"] as? Bool == false)
            #expect(body["max_output_tokens"] as? Int == 40)
            #expect(body["tools"] == nil)
            return fixture("""
                {"status":"completed","output":[{"type":"reasoning"},
                {"type":"message","role":"assistant","content":[{"type":"output_text","text":"First"},
                {"type":"output_text","text":"Second"}]}],
                "usage":{"input_tokens":32,"output_tokens":12}}
                """)
        }

        let output = try await client.generate(request(
            .openAI, "https://api.openai.com/v1/", apiKey: "example-key", maxOutputTokens: 40
        ))

        #expect(output.text == "First\nSecond")
        #expect(output.inputTokens == 32)
        #expect(output.outputTokens == 12)
    }

    @Test func anthropicReadsTextAndUsage() async throws {
        let client = ModelClient { outbound in
            #expect(outbound.url?.absoluteString == "https://api.anthropic.com/v1/messages")
            #expect(outbound.value(forHTTPHeaderField: "x-api-key") == "example-key")
            #expect(outbound.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

            let body = try Self.body(outbound)
            #expect(body["system"] as? String == "Project guidelines")
            #expect(body["max_tokens"] as? Int == 40)
            #expect(body["tools"] == nil)
            return fixture("""
                {"role":"assistant","stop_reason":"end_turn","content":[
                  {"type":"thinking","thinking":"hidden"},{"type":"text","text":"Answer"}],
                 "usage":{"input_tokens":11,"output_tokens":13,
                 "cache_creation_input_tokens":20,"cache_read_input_tokens":30}}
                """)
        }

        let output = try await client.generate(request(
            .anthropic, "https://api.anthropic.com", apiKey: "example-key", maxOutputTokens: 40
        ))

        #expect(output.text == "Answer")
        #expect(output.inputTokens == 61)
        #expect(output.outputTokens == 13)
    }

    @Test(arguments: [
        "https://api.openai.com.example/v1", "http://api.openai.com/v1",
        "https://api.openai.com:8080/v1", "https://operator@api.openai.com/v1",
        "https://api.openai.com/v1?leak=true", "https://api.openai.com//v1"
    ])
    func rejectsCredentialRedirectByConfiguration(endpoint: String) async {
        let client = ModelClient { _ in throw TestError.unexpectedRequest }

        await #expect(throws: ModelExecutionError.invalidConfiguration) {
            try await client.generate(request(.openAI, endpoint, apiKey: "example-key"))
        }
    }

    @Test func neverTreatsRemoteServicesAsLocal() async {
        let client = ModelClient { _ in throw TestError.unexpectedRequest }

        await #expect(throws: ModelExecutionError.invalidConfiguration) {
            try await client.generate(request(.ollama, "http://192.0.2.1:11434/api/chat"))
        }
    }

    @Test func sanitizesProviderErrors() async {
        let client = ModelClient { _ in fixture("Private provider error", status: 429) }

        await #expect(throws: ModelExecutionError.rateLimited) {
            try await client.generate(request(.openAI, "https://api.openai.com", apiKey: "example-key"))
        }
    }

    @Test func surfacesTruncationBeforeReturningAnIncompleteResult() async {
        let client = ModelClient { _ in
            fixture("""
                {"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},
                 "output":[]}
                """)
        }

        await #expect(throws: ModelExecutionError.outputLimit) {
            try await client.generate(request(.openAI, "https://api.openai.com", apiKey: "example-key"))
        }
    }

    private func request(
        _ provider: ModelProvider,
        _ endpoint: String,
        model: String = "example",
        apiKey: String? = nil,
        maxOutputTokens: Int = 2_048
    ) -> ModelRequest {
        ModelRequest(
            provider: provider,
            endpoint: URL(string: endpoint)!,
            model: model,
            apiKey: apiKey,
            system: "Project guidelines",
            messages: [ModelMessage(role: .user, text: "Summarize this project.")],
            maxOutputTokens: maxOutputTokens
        )
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private enum TestError: Error {
    case unexpectedRequest
}

private func fixture(_ payload: String, status: Int = 200) -> HTTPPayload {
    HTTPPayload(statusCode: status, body: Data(payload.utf8))
}
