import AidesCore
import Foundation
import Testing
@testable import AidesExecution

struct ComputerUseModelTests {
    private static let appID = "com.apple.TextEdit"
    private static let counterpart = "com.apple.Preview"
    private static let endpoint = URL(string: "http://127.0.0.1:11434")!
    private static let syntheticJPEG = Data([0xff, 0xd8, 0xff, 0xd9])

    @Test func requestsOneStructuredLocalDecisionAndRedactsSensitiveText() async throws {
        let planner = ComputerUseModel(client: ModelClient { outbound in
            #expect(outbound.url == Self.endpoint.appending(path: "/api/chat"))
            let body = try Self.body(outbound)
            #expect(body["model"] as? String == "fixture:local")
            #expect(body["format"] as? String == "json")
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.first?["role"] as? String == "system")
            #expect((messages.first?["content"] as? String)?.contains("untrusted data") == true)
            let user = try #require(messages.last)
            #expect(user["images"] as? [String] == [Self.syntheticJPEG.base64EncodedString()])
            let content = try #require(user["content"] as? String)
            #expect(content.contains("Update the draft"))
            #expect(content.contains("[sensitive text omitted]"))
            #expect(!content.contains("PRIVATE EXAMPLE VALUE"))
            #expect(!content.contains("field-2"))
            return try Self.fixture("""
                {"kind":"typeText","appID":"com.apple.TextEdit","elementID":"field-1","text":"Updated draft."}
                """)
        })
        let action = try await planner.decide(
            endpoint: Self.endpoint, model: "fixture", instruction: "Update the draft.",
            apps: Self.apps, observation: Self.observation(screenshot: Self.syntheticJPEG),
            recent: ["Previous action observed"]
        )
        #expect(action == ComputerAction(
            kind: .typeText, appID: Self.appID, elementID: "field-1", text: "Updated draft."
        ))
    }

    @Test(arguments: [
        #"{"kind":"click","appID":"com.apple.TextEdit","elementID":"stale"}"#,
        #"{"kind":"click","appID":"com.apple.TextEdit","elementID":"field-2"}"#,
        #"{"kind":"click","appID":"com.apple.Preview","elementID":"field-1"}"#,
        #"{"kind":"click","appID":"com.apple.TextEdit","x":0.5,"y":0.2}"#,
        #"{"kind":"activate","appID":"com.apple.Terminal"}"#,
        #"{"kind":"observe"}"#,
        #"{"kind":"key","appID":"com.apple.TextEdit","key":"Command+Q"}"#,
        #"{"kind":"scroll","appID":"com.apple.TextEdit","deltaY":9}"#,
        #"{"kind":"typeText","appID":"com.apple.TextEdit","elementID":"field-1","text":"password: fake"}"#,
        #"{"kind":"finish","text":"Done","another":true}"#,
        #"{"kind":"finish","text":"Done"} {"kind":"observe","appID":"com.apple.TextEdit"}"#,
        #"[{"kind":"finish","text":"Done"}]"#
    ])
    func failsClosedOnInvalidActions(_ output: String) async {
        let planner = ComputerUseModel(client: ModelClient { outbound in
            let messages = try #require(try Self.body(outbound)["messages"] as? [[String: Any]])
            #expect(messages.last?["images"] == nil)
            return try Self.fixture(output)
        })
        await #expect(throws: ModelExecutionError.unexpectedResponse) {
            try await planner.decide(
                endpoint: Self.endpoint, model: "fixture", instruction: "Update the draft.",
                apps: Self.apps, observation: Self.observation(), recent: []
            )
        }
    }

    @Test func acceptsVisualCoordinateOnlyWithTheCurrentWindowImage() async throws {
        let planner = ComputerUseModel(client: ModelClient { _ in
            try Self.fixture(#"{"kind":"click","appID":"com.apple.TextEdit","x":0.5,"y":0.2}"#)
        })
        let action = try await planner.decide(
            endpoint: Self.endpoint, model: "fixture", instruction: "Click the open panel.",
            apps: Self.apps, observation: Self.observation(screenshot: Self.syntheticJPEG), recent: []
        )
        #expect(action == ComputerAction(kind: .click, appID: Self.appID, x: 0.5, y: 0.2))
    }

    @Test func neverSendsScreenshotsToCloudAndRejectsNonLoopbackOllama() async {
        let planner = ComputerUseModel(client: ModelClient { _ in throw ModelExecutionError.unexpectedResponse })
        await #expect(throws: ModelExecutionError.invalidConfiguration) {
            try await planner.decide(
                endpoint: URL(string: "http://192.0.2.1:11434")!, model: "fixture",
                instruction: "Read the draft.", apps: Self.apps,
                observation: Self.observation(screenshot: Self.syntheticJPEG), recent: []
            )
        }

        let client = ModelClient { _ in throw ModelExecutionError.unexpectedResponse }
        for provider in [ModelProvider.openAI, .anthropic] {
            await #expect(throws: ModelExecutionError.invalidConfiguration) {
                try await client.generate(ModelRequest(
                    provider: provider, endpoint: URL(string: "https://api.openai.com")!, model: "fixture",
                    messages: [ModelMessage(role: .user, text: "Read the draft.", images: [Self.syntheticJPEG])]
                ))
            }
        }
    }

    @Test func treatsTruncationAsAnErrorEvenIfPartialOutputParses() async {
        let planner = ComputerUseModel(client: ModelClient { _ in
            try Self.fixture(#"{"kind":"finish","text":"Completed"}"#, reason: "length")
        })
        await #expect(throws: ModelExecutionError.outputLimit) {
            try await planner.decide(
                endpoint: Self.endpoint, model: "fixture", instruction: "Read the draft.",
                apps: Self.apps, observation: Self.observation(), recent: []
            )
        }
    }

    private static var apps: [ComputerApp] {
        [ComputerApp(id: appID, name: "TextEdit"), ComputerApp(id: counterpart, name: "Preview")]
    }

    private static func observation(screenshot: Data? = nil) -> ComputerObservation {
        ComputerObservation(
            appID: appID, windowTitle: "Test Document",
            elements: [
                ComputerElement(id: "field-1", role: "AXTextArea", label: "Document",
                                value: "api_key: PRIVATE EXAMPLE VALUE"),
                ComputerElement(id: "field-2", role: "AXSecureTextField", label: "Password", value: "hidden")
            ],
            screenshot: screenshot
        )
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        let bytes = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    private static func fixture(_ content: String, reason: String = "stop") throws -> HTTPPayload {
        try HTTPPayload(statusCode: 200, body: JSONSerialization.data(withJSONObject: [
            "message": ["role": "assistant", "content": content],
            "done": true, "done_reason": reason
        ]))
    }
}
