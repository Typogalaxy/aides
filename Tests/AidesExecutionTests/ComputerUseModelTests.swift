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

    @Test func acceptsScopedDragMoveDoubleClickAndRightClick() async throws {
        let inputs = [
            (#"{"kind":"drag","appID":"com.apple.TextEdit","x":0.2,"y":0.3,"endX":0.7,"endY":0.8}"#, ComputerActionKind.drag),
            (#"{"kind":"movePointer","appID":"com.apple.TextEdit","x":0.5,"y":0.2}"#, .movePointer),
            (#"{"kind":"click","appID":"com.apple.TextEdit","x":0.5,"y":0.2,"button":"left","clickCount":2}"#, .click),
            (#"{"kind":"click","appID":"com.apple.TextEdit","x":0.5,"y":0.2,"button":"right"}"#, .click)
        ]
        for (input, kind) in inputs {
            let planner = ComputerUseModel(client: ModelClient { _ in try Self.fixture(input) })
            let action = try await planner.decide(
                endpoint: Self.endpoint, model: "fixture", instruction: "Interact with the open panel.",
                apps: Self.apps, observation: Self.observation(screenshot: Self.syntheticJPEG), recent: []
            )
            #expect(action.kind == kind)
        }
    }

    @Test(arguments: [
        #"{"kind":"drag","appID":"com.apple.TextEdit","x":0.2,"y":0.3,"endX":0.7}"#,
        #"{"kind":"drag","appID":"com.apple.TextEdit","x":0.2,"y":0.3,"endX":1.2,"endY":0.8}"#,
        #"{"kind":"drag","appID":"com.apple.Preview","x":0.2,"y":0.3,"endX":0.7,"endY":0.8}"#,
        #"{"kind":"movePointer","appID":"com.apple.TextEdit","elementID":"field-1"}"#,
        #"{"kind":"click","appID":"com.apple.TextEdit","elementID":"field-1","button":"right"}"#,
        #"{"kind":"click","appID":"com.apple.TextEdit","elementID":"field-1","clickCount":2}"#,
        #"{"kind":"click","appID":"com.apple.TextEdit","x":0.5,"y":0.2,"clickCount":3}"#,
        #"{"kind":"click","appID":"com.apple.TextEdit","x":0.5,"y":0.2,"button":"other"}"#
    ])
    func rejectsMalformedPointerGestureEvenWithAnImage(_ input: String) async {
        let planner = ComputerUseModel(client: ModelClient { _ in try Self.fixture(input) })
        await #expect(throws: ModelExecutionError.unexpectedResponse) {
            try await planner.decide(
                endpoint: Self.endpoint, model: "fixture", instruction: "Interact with the open panel.",
                apps: Self.apps, observation: Self.observation(screenshot: Self.syntheticJPEG), recent: []
            )
        }
    }

    @Test(arguments: [
        #"{"kind":"drag","appID":"com.apple.TextEdit","x":0.2,"y":0.3,"endX":0.7,"endY":0.8}"#,
        #"{"kind":"movePointer","appID":"com.apple.TextEdit","x":0.5,"y":0.2}"#
    ])
    func rejectsPointerGesturesWithoutForegroundImage(_ input: String) async {
        let planner = ComputerUseModel(client: ModelClient { _ in try Self.fixture(input) })
        for background in [false, true] {
            await #expect(throws: ModelExecutionError.unexpectedResponse) {
                try await planner.decide(
                    endpoint: Self.endpoint, model: "fixture", instruction: "Interact with the open panel.",
                    apps: Self.apps, observation: Self.observation(), recent: [], allowBackground: background
                )
            }
        }
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

    @Test func appshotSharesOnlyBoundedWindowEvidenceWithLocalModels() async throws {
        let planner = ComputerUseModel(client: ModelClient { _ in throw ModelExecutionError.unexpectedResponse })
        let message = try planner.appshotMessage(Self.observation())
        #expect(message.localOnly == true)
        #expect(message.images == nil)
        #expect(message.text.contains("Test Document"))
        #expect(message.text.contains("[sensitive text omitted]"))
        #expect(!message.text.contains("PRIVATE EXAMPLE VALUE"))
        #expect(!message.text.contains("field-2"))
        #expect(!message.text.contains(#""instruction""#))
        #expect(!message.text.contains(#""recent""#))

        let client = ModelClient { _ in throw ModelExecutionError.unexpectedResponse }
        await #expect(throws: ModelExecutionError.invalidConfiguration) {
            try await client.generate(ModelRequest(
                provider: .openAI, endpoint: URL(string: "https://api.openai.com")!, model: "fixture",
                messages: [message]
            ))
        }
    }

    @Test func appshotOmitsOversizeMetadataAndRejectsOversizeImage() throws {
        let planner = ComputerUseModel()
        let window = ComputerObservation(
            appID: Self.appID, windowTitle: String(repeating: "x", count: 500),
            elements: [ComputerElement(id: "field-1", role: "AXTextArea", label: "Document",
                                       value: String(repeating: "a", count: 2_000) + " private tail")],
            screenshot: Self.syntheticJPEG
        )
        let message = try planner.appshotMessage(window)
        #expect(message.images == [Self.syntheticJPEG])
        #expect(!message.text.contains(String(repeating: "x", count: 257)))
        #expect(!message.text.contains(String(repeating: "a", count: 1_025)))
        #expect(!message.text.contains("private tail"))

        #expect(throws: ModelExecutionError.invalidConfiguration) {
            try planner.appshotMessage(Self.observation(
                screenshot: Self.syntheticJPEG + Data(repeating: 0, count: ComputerObservation.maximumImageBytes)
            ))
        }
    }

    @Test func backgroundRunsSendAXOnlyAndAllowObservingAnotherAuthorizedApp() async throws {
        let planner = ComputerUseModel(client: ModelClient { outbound in
            let messages = try #require(try Self.body(outbound)["messages"] as? [[String: Any]])
            #expect((messages.first?["content"] as? String)?.contains("background accessibility actions") == true)
            #expect(messages.last?["images"] == nil)
            return try Self.fixture(#"{"kind":"observe","appID":"com.apple.Preview"}"#)
        })
        let action = try await planner.decide(
            endpoint: Self.endpoint, model: "fixture", instruction: "Look at both windows.",
            apps: Self.apps, observation: Self.observation(), recent: [], allowBackground: true
        )
        #expect(action == ComputerAction(kind: .observe, appID: Self.counterpart))
    }

    @Test(arguments: [
        #"{"kind":"activate","appID":"com.apple.Preview"}"#,
        #"{"kind":"key","appID":"com.apple.TextEdit","key":"Tab"}"#,
        #"{"kind":"scroll","appID":"com.apple.TextEdit","deltaY":3}"#
    ])
    func refusesForegroundActionsDuringBackgroundRun(_ output: String) async {
        let planner = ComputerUseModel(client: ModelClient { _ in try Self.fixture(output) })
        await #expect(throws: ModelExecutionError.unexpectedResponse) {
            try await planner.decide(
                endpoint: Self.endpoint, model: "fixture", instruction: "Read the draft.",
                apps: Self.apps, observation: Self.observation(), recent: [], allowBackground: true
            )
        }
    }

    @Test func retainsOnlyTwoPreviouslyAuthorizedWindowsAndNoStaleControls() async throws {
        let planner = ComputerUseModel(client: ModelClient { outgoing in
            let messages = try #require(try Self.body(outgoing)["messages"] as? [[String: Any]])
            let userMessage = try #require(messages.last)
            let content = try #require(userMessage["content"] as? String)
            let evidence = try #require(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
            let windows = try #require(evidence["priorWindows"] as? [[String: Any]])
            #expect(windows.compactMap { $0["appID"] as? String } == ["com.apple.Notes", Self.counterpart])
            #expect(content.contains("Selected text: Preserve this paragraph"))
            #expect(content.contains("Authorized older text"))
            for omitted in ["UNAUTHORIZED", "STALE CONTROL ID", "DUPLICATE", "NOT RECENT", "ACTIVE OLD"] {
                #expect(!content.contains(omitted))
            }
            #expect(windows.allSatisfy { $0["screenshot"] == nil && $0["elements"] == nil })
            #expect(userMessage["images"] == nil)
            return try Self.fixture(#"{"kind":"typeText","appID":"com.apple.TextEdit","elementID":"field-1","text":"Preserve this paragraph"}"#)
        })
        let apps = Self.apps + [
            ComputerApp(id: "com.apple.Notes", name: "Notes"),
            ComputerApp(id: "com.apple.Dictionary", name: "Dictionary")
        ]
        let action = try await planner.decide(
            endpoint: Self.endpoint, model: "fixture", instruction: "Copy the selected note into the draft.",
            apps: apps, observation: Self.observation(), recent: [],
            priorWindows: [
                Self.prior("com.apple.Dictionary", "NOT RECENT"),
                Self.prior(Self.counterpart, "DUPLICATE"),
                Self.prior(Self.counterpart, "Authorized older text"),
                Self.prior(Self.appID, "ACTIVE OLD"),
                Self.prior("com.apple.Notes", "Selected text: Preserve this paragraph"),
                Self.prior("com.apple.Terminal", "UNAUTHORIZED")
            ]
        )
        #expect(action.text == "Preserve this paragraph")
    }

    @Test func priorWindowCannotGrantAnElementID() async {
        let planner = ComputerUseModel(client: ModelClient { _ in
            try Self.fixture(#"{"kind":"click","appID":"com.apple.TextEdit","elementID":"STALE CONTROL ID"}"#)
        })
        await #expect(throws: ModelExecutionError.unexpectedResponse) {
            try await planner.decide(
                endpoint: Self.endpoint, model: "fixture", instruction: "Inspect both windows.",
                apps: Self.apps, observation: Self.observation(), recent: [],
                priorWindows: [Self.prior(Self.counterpart, "Previous authorized window")]
            )
        }
    }

    private static func prior(_ id: String, _ value: String) -> ComputerObservation {
        ComputerObservation(
            appID: id, windowTitle: "Prior window",
            elements: [ComputerElement(id: "STALE CONTROL ID", role: "AXTextArea", label: "Document", value: value)],
            screenshot: syntheticJPEG
        )
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
