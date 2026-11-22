import AidesCore
import Foundation

extension ToolkitMailConnector {
    private static let outlookHost = "graph.microsoft.com"
    private static let outlookMailbox = "/v1.0/me"
    private static let messageProperties = "id,subject,from,bodyPreview,receivedDateTime"

    func checkOutlookAccount(_ account: ToolkitMailAccount, token: String) async throws {
        let profile = try await get(
            OutlookProfile.self, host: Self.outlookHost, path: Self.outlookMailbox, token: token,
            query: [.init(name: "$select", value: "mail,userPrincipalName")]
        )
        guard let providerAddress = profile.mail ?? profile.userPrincipalName,
              providerAddress.caseInsensitiveCompare(account.address) == .orderedSame else {
            throw ToolkitMailConnectorError.wrongAccount
        }
    }

    func outlookSearch(token: String, query: String, limit: Int) async throws -> [ToolkitMailMessage] {
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let response = try await get(
            OutlookSearch.self, host: Self.outlookHost, path: Self.outlookMailbox + "/messages", token: token,
            query: [.init(name: "$search", value: "\"\(escaped)\""), .init(name: "$top", value: String(limit)),
                    .init(name: "$select", value: Self.messageProperties)],
            headers: ["Prefer": "IdType=\"ImmutableId\""]
        )
        return response.value.prefix(limit).map { $0.message(includeBody: false) }
    }

    func outlookMessage(token: String, id: String, includeBody: Bool) async throws -> ToolkitMailMessage {
        let path = Self.outlookMailbox + "/messages/" + id
        let message = try await get(
            OutlookMessage.self, host: Self.outlookHost, path: path, token: token,
            query: [.init(name: "$select", value: Self.messageProperties + (includeBody ? ",body,hasAttachments" : ""))],
            headers: ["Prefer": "outlook.body-content-type=\"text\", IdType=\"ImmutableId\""]
        )
        let attachments: [ToolkitMailAttachment]
        if includeBody && message.hasAttachments == true {
            let response = try await get(
                OutlookAttachments.self, host: Self.outlookHost, path: path + "/attachments", token: token,
                query: [.init(name: "$select", value: "name,contentType,size,isInline"), .init(name: "$top", value: "24")]
            )
            attachments = response.value.prefix(24).compactMap { $0.metadata }
        } else {
            attachments = []
        }
        return message.message(includeBody: includeBody, attachments: attachments)
    }

    func outlookArchive(token: String, id: String) async throws {
        let inbox = try await get(
            OutlookFolder.self, host: Self.outlookHost, path: Self.outlookMailbox + "/mailFolders/inbox", token: token,
            query: [.init(name: "$select", value: "id")]
        )
        let path = Self.outlookMailbox + "/messages/" + id
        let headers = ["Prefer": "IdType=\"ImmutableId\""]
        let location = try await get(
            OutlookLocation.self, host: Self.outlookHost, path: path, token: token,
            query: [.init(name: "$select", value: "parentFolderId")], headers: headers
        )
        guard location.parentFolderId == inbox.id else { return }
        try await submit(request(
            host: Self.outlookHost, path: Self.outlookMailbox + "/mailFolders/inbox/messages/" + id + "/move", token: token,
            headers: headers, body: json(["destinationId": "archive"])
        ))
    }

    func outlookSend(token: String, draft: ToolkitMailDraft) async throws {
        let message: [String: Any] = [
            "subject": draft.subject,
            "body": ["contentType": "Text", "content": draft.body],
            "toRecipients": draft.to.map { ["emailAddress": ["address": $0]] },
            "internetMessageHeaders": [["name": "x-aides-invocation-id", "value": draft.id.uuidString]]
        ]
        try await submit(request(
            host: Self.outlookHost, path: Self.outlookMailbox + "/sendMail", token: token,
            body: json(["message": message])
        ))
    }
}

private struct OutlookProfile: Decodable {
    let mail: String?
    let userPrincipalName: String?
}

private struct OutlookSearch: Decodable { let value: [OutlookMessage] }
private struct OutlookFolder: Decodable { let id: String }
private struct OutlookLocation: Decodable { let parentFolderId: String }

private struct OutlookAttachments: Decodable {
    struct Entry: Decodable {
        let name: String?
        let contentType: String?
        let size: Int?
        let isInline: Bool?

        var metadata: ToolkitMailAttachment? {
            guard let name, !name.isEmpty else { return nil }
            return ToolkitMailAttachment(
                name: ToolkitRemoteTransport.bounded(name, limit: 512),
                contentType: contentType.map { ToolkitRemoteTransport.bounded($0, limit: 120) },
                byteCount: size.flatMap { $0 >= 0 ? $0 : nil },
                isInline: isInline ?? false
            )
        }
    }

    let value: [Entry]
}

private struct OutlookMessage: Decodable {
    struct Sender: Decodable {
        struct Address: Decodable { let address: String? }
        let emailAddress: Address?
    }

    struct Body: Decodable {
        let contentType: String
        let content: String?
    }

    let id: String
    let subject: String?
    let from: Sender?
    let bodyPreview: String?
    let receivedDateTime: String?
    let body: Body?
    let hasAttachments: Bool?

    func message(includeBody: Bool, attachments: [ToolkitMailAttachment] = []) -> ToolkitMailMessage {
        let plain = body?.contentType.caseInsensitiveCompare("text") == .orderedSame ? body?.content : nil
        return ToolkitMailMessage(
            id: id, subject: ToolkitRemoteTransport.bounded(subject, limit: 512),
            from: ToolkitRemoteTransport.bounded(from?.emailAddress?.address, limit: 512),
            preview: ToolkitRemoteTransport.bounded(bodyPreview, limit: 1_024),
            body: includeBody ? plain.map { ToolkitRemoteTransport.bounded($0, limit: 24_000) } : nil,
            receivedAt: ToolkitRemoteTransport.date(receivedDateTime), attachments: attachments
        )
    }
}
