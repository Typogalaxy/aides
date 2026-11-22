import AidesCore
@testable import AidesExecution
import Foundation
import Testing

struct ToolkitMailConnectorTests {
    @Test func gmailUsesReadAndSendEndpointsWithTheConfiguredSender() async throws {
        let account = makeAccount(.gmail)
        let draft = makeDraft(account)
        let connector = ToolkitMailConnector { request in
            let url = try #require(request.url)
            #expect(url.host == "gmail.googleapis.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            switch url.path {
            case "/gmail/v1/users/me/profile":
                return Data(#"{"emailAddress":"owner@example.com"}"#.utf8)
            case "/gmail/v1/users/me/messages":
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "topic+a")
                #expect(url.absoluteString.contains("%2B"))
                return Data(#"{"messages":[{"id":"abc123"}]}"#.utf8)
            case "/gmail/v1/users/me/messages/abc123":
                return Data(#"{"id":"abc123","snippet":"Preview","internalDate":"1795305600000","payload":{"mimeType":"multipart/mixed","headers":[{"name":"From","value":"sender@example.com"},{"name":"subject","value":"Fixture subject"}],"parts":[{"mimeType":"text/plain","body":{"data":"SGVsbG8"}},{"mimeType":"application/pdf","filename":"fixture.pdf","body":{"attachmentId":"private-id","size":21}}]}}"#.utf8)
            case "/gmail/v1/users/me/messages/abc123/modify":
                #expect(request.httpMethod == "POST")
                let object = try requestObject(request)
                #expect(object["removeLabelIds"] as? [String] == ["INBOX"])
                return Data()
            case "/gmail/v1/users/me/messages/send":
                #expect(request.httpMethod == "POST")
                let object = try requestObject(request)
                let encoded = try #require(object["raw"] as? String)
                var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
                let message = String(decoding: try #require(Data(base64Encoded: base64)), as: UTF8.self)
                #expect(message.contains("From: owner@example.com\r\nTo: recipient@example.com"))
                #expect(message.contains("Message-ID: <\(draft.id.uuidString.lowercased())@example.com>"))
                #expect(message.contains(Data(draft.body.utf8).base64EncodedString()))
                return Data()
            default:
                Issue.record("Unexpected Gmail fixture endpoint: \(url.path)")
                return Data()
            }
        }
        let result = try await connector.search(account: account, token: "fixture-token", query: "topic+a", limit: 3)
        #expect(result.first?.subject == "Fixture subject")
        #expect(result.first?.body == nil)
        let message = try await connector.read(account: account, token: "fixture-token", messageID: "abc123")
        #expect(message.body == "Hello")
        #expect(message.receivedAt != nil)
        #expect(message.attachments.first?.name == "fixture.pdf")
        #expect(message.attachments.first?.byteCount == 21)
        try await connector.send(draft: draft, account: account, token: "fixture-token")
        try await connector.archive(account: account, token: "fixture-token", messageID: "abc123")
    }

    @Test func outlookUsesImmutableIDsAndPlainText() async throws {
        let account = makeAccount(.outlook)
        let draft = makeDraft(account)
        let connector = ToolkitMailConnector { request in
            let url = try #require(request.url)
            #expect(url.host == "graph.microsoft.com")
            switch url.path {
            case "/v1.0/me": return Data(#"{"mail":"owner@example.com"}"#.utf8)
            case "/v1.0/me/messages":
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "\"project\"")
                #expect(request.value(forHTTPHeaderField: "Prefer")?.contains("ImmutableId") == true)
                return Data(#"{"value":[{"id":"id-a","subject":"Fixture","bodyPreview":"Preview"}]}"#.utf8)
            case "/v1.0/me/messages/id-a":
                #expect(request.value(forHTTPHeaderField: "Prefer")?.contains("ImmutableId") == true)
                return Data(#"{"id":"id-a","subject":"Fixture","parentFolderId":"original-inbox","hasAttachments":true,"receivedDateTime":"2026-11-22T01:00:00Z","body":{"contentType":"text","content":"Hello"}}"#.utf8)
            case "/v1.0/me/messages/id-a/attachments":
                return Data(#"{"value":[{"name":"outlook.pdf","contentType":"application/pdf","size":10,"isInline":false}]}"#.utf8)
            case "/v1.0/me/mailFolders/inbox":
                return Data(#"{"id":"original-inbox"}"#.utf8)
            case "/v1.0/me/mailFolders/inbox/messages/id-a/move":
                let object = try requestObject(request)
                #expect(object["destinationId"] as? String == "archive")
                return Data()
            case "/v1.0/me/sendMail":
                let object = try requestObject(request)
                let message = try #require(object["message"] as? [String: Any])
                let body = try #require(message["body"] as? [String: String])
                #expect(body["content"] == draft.body)
                let recipients = message["toRecipients"] as? [[String: [String: String]]]
                #expect(recipients?.first?["emailAddress"]?["address"] == "recipient@example.com")
                return Data()
            default:
                Issue.record("Unexpected Outlook fixture endpoint: \(url.path)")
                return Data()
            }
        }
        let result = try await connector.search(account: account, token: "fixture-token", query: "project", limit: 3)
        #expect(result.first?.id == "id-a")
        let message = try await connector.read(account: account, token: "fixture-token", messageID: "id-a")
        #expect(message.body == "Hello")
        #expect(message.receivedAt != nil)
        #expect(message.attachments.first?.name == "outlook.pdf")
        try await connector.send(draft: draft, account: account, token: "fixture-token")
        try await connector.archive(account: account, token: "fixture-token", messageID: "id-a")
    }

    @Test func fastmailLooksUpSessionAndIdentityAndSubmitsExplicitDraft() async throws {
        let account = makeAccount(.fastmail)
        let draft = makeDraft(account)
        let connector = ToolkitMailConnector { request in
            let url = try #require(request.url)
            #expect(url.host == "api.fastmail.com")
            guard url.path != "/jmap/session" else {
                return Data(#"{"apiUrl":"https://api.fastmail.com/jmap/api/","username":"owner@example.com","primaryAccounts":{"urn:ietf:params:jmap:mail":"account","urn:ietf:params:jmap:submission":"account"}}"#.utf8)
            }
            #expect(url.path == "/jmap/api" || url.path == "/jmap/api/")
            let object = try requestObject(request)
            let calls = try #require(object["methodCalls"] as? [[Any]])
            let call = try #require(calls.first)
            let name = try #require(call.first as? String)
            let input = try #require(call[1] as? [String: Any])
            #expect(input["accountId"] as? String == "account")
            let result: String
            switch name {
            case "Email/query":
                result = #"{"ids":["abc"]}"#
                #expect((input["filter"] as? [String: String])?["text"] == "project")
            case "Email/get":
                result = #"{"state":"state-before","list":[{"id":"abc","subject":"Fixture","receivedAt":"2026-11-22T01:00:00.123Z","mailboxIds":{"inbox-id":true},"attachments":[{"name":"fastmail.pdf","type":"application/pdf","size":42,"disposition":"attachment"}],"textBody":[{"partId":"a","type":"text/plain"}],"bodyValues":{"a":{"value":"Hello"}}}]}"#
                #expect(input["ids"] as? [String] == ["abc"])
            case "Identity/get":
                result = #"{"list":[{"id":"identity","email":"owner@example.com"}]}"#
            case "Mailbox/get":
                result = #"{"list":[{"id":"d","role":"drafts"},{"id":"s","role":"sent"},{"id":"inbox-id","role":"inbox"},{"id":"archive-id","role":"archive"}]}"#
            case "Email/set":
                if let update = input["update"] as? [String: [String: Any]] {
                    #expect(input["ifInState"] as? String == "state-before")
                    #expect(update["abc"]?["mailboxIds/inbox-id"] is NSNull)
                    #expect(update["abc"]?["mailboxIds/archive-id"] as? Bool == true)
                    result = #"{"updated":{"abc":null}}"#
                } else {
                    let create = input["create"] as? [String: [String: Any]]
                    #expect(create?["draft"]?["subject"] as? String == draft.subject)
                    #expect((create?["draft"]?["mailboxIds"] as? [String: Bool])?["d"] == true)
                    result = #"{"created":{"draft":{"id":"new-email"}}}"#
                }
            case "EmailSubmission/set":
                let create = input["create"] as? [String: [String: String]]
                #expect(create?["send"]?["emailId"] == "new-email")
                #expect(create?["send"]?["identityId"] == "identity")
                result = #"{"created":{"send":{"id":"new-send"}}}"#
            default:
                Issue.record("Unexpected Fastmail fixture method: \(name)")
                result = "{}"
            }
            return Data("{\"methodResponses\":[[\"\(name)\",\(result),\"request\"]]}".utf8)
        }
        let result = try await connector.search(account: account, token: "fixture-token", query: "project", limit: 3)
        #expect(result.first?.id == "abc")
        #expect(result.first?.body == nil)
        let message = try await connector.read(account: account, token: "fixture-token", messageID: "abc")
        #expect(message.body == "Hello")
        #expect(message.receivedAt != nil)
        #expect(message.attachments.first?.name == "fastmail.pdf")
        try await connector.send(draft: draft, account: account, token: "fixture-token")
        try await connector.archive(account: account, token: "fixture-token", messageID: "abc")
    }

    @Test func fastmailRejectsAnAPIEndpointOnAnotherOrigin() async throws {
        let account = makeAccount(.fastmail)
        let connector = ToolkitMailConnector { request in
            #expect(request.url?.host == "api.fastmail.com")
            #expect(request.url?.path == "/jmap/session")
            return Data(#"{"apiUrl":"https://wrong.example.org/jmap/api/","username":"owner@example.com","primaryAccounts":{"urn:ietf:params:jmap:mail":"account"}}"#.utf8)
        }
        await #expect(throws: ToolkitMailConnectorError.unexpectedResponse) {
            try await connector.search(account: account, token: "fixture-token", query: "project", limit: 3)
        }
    }

    @Test func gmailRejectsMismatchedAccountBeforeItCanSend() async throws {
        let account = makeAccount(.gmail)
        let connector = ToolkitMailConnector { request in
            #expect(request.url?.path == "/gmail/v1/users/me/profile")
            return Data(#"{"emailAddress":"different@example.com"}"#.utf8)
        }
        await #expect(throws: ToolkitMailConnectorError.wrongAccount) {
            try await connector.send(draft: makeDraft(account), account: account, token: "fixture-token")
        }
    }
}

private func makeAccount(_ provider: ToolkitMailProvider) -> ToolkitMailAccount {
    ToolkitMailAccount(
        id: "fixture", provider: provider, label: "Fixture", address: "owner@example.com",
        available: true, allowSend: true
    )
}

private func makeDraft(_ account: ToolkitMailAccount) -> ToolkitMailDraft {
    ToolkitMailDraft(
        request: ToolkitMailDraftRequest(
            accountID: account.id, to: ["recipient@example.com"], subject: "Test 邮件", body: "Test\nbody"
        ),
        account: account, requestedByDeviceID: UUID(), now: .now
    )
}

private func requestObject(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
