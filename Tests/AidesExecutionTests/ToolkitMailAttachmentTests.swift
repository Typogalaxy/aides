import AidesCore
@testable import AidesExecution
import Foundation
import Testing

struct ToolkitMailAttachmentTests {
    @Test func gmailBindsSelectionAndDownloadsOnlyTheSelectedTextAttachment() async throws {
        let account = makeAccount(.gmail)
        let paths = AttachmentFixturePaths()
        let connector = ToolkitMailConnector { request in
            let url = try #require(request.url)
            await paths.record(url.path)
            #expect(url.host == "gmail.googleapis.com")
            switch url.path {
            case "/gmail/v1/users/me/profile":
                return Data(#"{"emailAddress":"owner@example.com"}"#.utf8)
            case "/gmail/v1/users/me/messages/abc":
                if let field = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "fields" }) {
                    #expect(field.value?.contains("body(attachmentId,size)") == true)
                    #expect(field.value?.contains("data") == false)
                }
                return Data(#"{"id":"abc","payload":{"parts":[{"filename":"note.txt","mimeType":"text/plain","body":{"size":4,"attachmentId":"native-id"}},{"filename":"other.pdf","mimeType":"application/pdf","body":{"size":2,"attachmentId":"pdf-id"}},{"filename":"large.txt","mimeType":"text/plain","body":{"size":16385,"attachmentId":"large-id"}}]}}"#.utf8)
            case "/gmail/v1/users/me/messages/abc/attachments/native-id":
                return Data(#"{"data":"bGlzdA","size":4}"#.utf8)
            default:
                Issue.record("Unexpected Gmail attachment path: \(url.path)")
                return Data()
            }
        }
        let message = try await connector.read(account: account, token: "fixture-token", messageID: "abc")
        #expect(message.attachments.count == 3)
        #expect(message.attachments.dropFirst().allSatisfy { $0.previewKey == nil })
        #expect(await paths.count(containing: "/attachments/") == 0)
        let invalid = ToolkitMailAttachmentPreviewRequest(index: 0, previewKey: String(repeating: "0", count: 64))
        await #expect(throws: ToolkitMailAttachmentPreviewError.changed) {
            try await connector.previewAttachment(account: account, token: "fixture-token", messageID: "abc", selection: invalid)
        }
        #expect(await paths.count(containing: "/attachments/") == 0)

        let key = try #require(message.attachments.first?.previewKey)
        let result = try await connector.previewAttachment(
            account: account, token: "fixture-token", messageID: "abc",
            selection: ToolkitMailAttachmentPreviewRequest(index: 0, previewKey: key)
        )
        #expect(result.name == "note.txt")
        #expect(result.contentType == "text/plain")
        #expect(result.text == "list")
        #expect(await paths.count(containing: "/attachments/") == 1)
    }

    @Test func outlookUsesRawFileEndpointAndRejectsBinaryWithTextMetadata() async throws {
        let account = makeAccount(.outlook)
        let paths = AttachmentFixturePaths()
        let connector = ToolkitMailConnector { request in
            let url = try #require(request.url)
            await paths.record(url.path)
            #expect(url.host == "graph.microsoft.com")
            switch url.path {
            case "/v1.0/me":
                return Data(#"{"mail":"owner@example.com"}"#.utf8)
            case "/v1.0/me/messages/id-a":
                return Data(#"{"id":"id-a","hasAttachments":true}"#.utf8)
            case "/v1.0/me/messages/id-a/attachments":
                return Data(#"{"value":[{"@odata.type":"#microsoft.graph.fileAttachment","id":"native-id","name":"note.txt","contentType":"text/plain; charset=UTF-8","size":4},{"@odata.type":"#microsoft.graph.referenceAttachment","id":"link-native","name":"link.txt","contentType":"text/plain","size":4}]}"#.utf8)
            case "/v1.0/me/messages/id-a/attachments/native-id/$value":
                return Data([0xFF, 0, 21, 42])
            default:
                Issue.record("Unexpected Outlook attachment path: \(url.path)")
                return Data()
            }
        }
        let message = try await connector.read(account: account, token: "fixture-token", messageID: "id-a")
        #expect(message.attachments.count == 2)
        #expect(message.attachments.last?.previewKey == nil)
        let key = try #require(message.attachments.first?.previewKey)
        await #expect(throws: ToolkitMailAttachmentPreviewError.unsupported) {
            try await connector.previewAttachment(
                account: account, token: "fixture-token", messageID: "id-a",
                selection: ToolkitMailAttachmentPreviewRequest(index: 0, previewKey: key)
            )
        }
        #expect(await paths.count(containing: "/$value") == 1)
    }

    @Test func fastmailUsesOnlyItsDocumentedAuthenticatedDownloadTemplate() async throws {
        let account = makeAccount(.fastmail)
        let fixturePayload = Data(#"{"methodResponses":[["Email/get",{"list":[{"id":"abc","attachments":[{"blobId":"native-id","name":"untrusted/payload.txt","type":"text/plain","size":4}]}]},"request"]]}"#.utf8)
        let connector = ToolkitMailConnector { request in
            let url = try #require(request.url)
            switch (url.host, url.path) {
            case ("api.fastmail.com", "/jmap/session"):
                return Data(#"{"apiUrl":"https://api.fastmail.com/jmap/api/","downloadUrl":"https://www.fastmailusercontent.com/jmap/download/{accountId}/{blobId}/{name}?type={type}","username":"owner@example.com","primaryAccounts":{"urn:ietf:params:jmap:mail":"account"}}"#.utf8)
            case ("api.fastmail.com", "/jmap/api"), ("api.fastmail.com", "/jmap/api/"):
                return fixturePayload
            case ("www.fastmailusercontent.com", "/jmap/download/account/native-id/preview.txt"):
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "text/plain")
                #expect(url.absoluteString.contains("untrusted") == false)
                return Data("safe".utf8)
            default:
                Issue.record("Unexpected Fastmail attachment endpoint: \(url.host ?? "")\(url.path)")
                return Data()
            }
        }
        let message = try await connector.read(account: account, token: "fixture-token", messageID: "abc")
        let key = try #require(message.attachments.first?.previewKey)
        let preview = try await connector.previewAttachment(
            account: account, token: "fixture-token", messageID: "abc",
            selection: ToolkitMailAttachmentPreviewRequest(index: 0, previewKey: key)
        )
        #expect(preview.text == "safe")
        #expect(preview.name == "untrusted/payload.txt")

        let unavailable = ToolkitMailConnector { request in
            let url = try #require(request.url)
            #expect(url.host == "api.fastmail.com")
            if url.path == "/jmap/session" {
                return Data(#"{"apiUrl":"https://api.fastmail.com/jmap/api/","downloadUrl":"https://evil.example.org/jmap/download/{accountId}/{blobId}/{name}?type={type}","username":"owner@example.com","primaryAccounts":{"urn:ietf:params:jmap:mail":"account"}}"#.utf8)
            }
            return fixturePayload
        }
        let locked = try await unavailable.read(account: account, token: "fixture-token", messageID: "abc")
        #expect(locked.attachments.count == 1)
        #expect(locked.attachments.first?.previewKey == nil)
        await #expect(throws: ToolkitMailAttachmentPreviewError.unsupported) {
            try await unavailable.previewAttachment(
                account: account, token: "fixture-token", messageID: "abc",
                selection: ToolkitMailAttachmentPreviewRequest(index: 0, previewKey: key)
            )
        }
    }
}

private actor AttachmentFixturePaths {
    private var paths: [String] = []

    func record(_ path: String) { paths.append(path) }

    func count(containing fragment: String) -> Int {
        paths.filter { $0.contains(fragment) }.count
    }
}

private func makeAccount(_ provider: ToolkitMailProvider) -> ToolkitMailAccount {
    ToolkitMailAccount(
        id: "fixture", provider: provider, label: "Attachment fixture", address: "owner@example.com",
        available: true, allowSend: false
    )
}
