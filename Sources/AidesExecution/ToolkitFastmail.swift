import AidesCore
import Foundation

struct FastmailSession: Decodable, Sendable {
    let apiUrl: URL
    let downloadUrl: String?
    let username: String
    let primaryAccounts: [String: String]
}

extension ToolkitMailConnector {
    private static let fastmailHost = "api.fastmail.com"
    private static let jmapCore = "urn:ietf:params:jmap:core"
    private static let jmapMail = "urn:ietf:params:jmap:mail"
    private static let jmapSubmission = "urn:ietf:params:jmap:submission"

    func fastmailSession(_ account: ToolkitMailAccount, token: String) async throws -> FastmailSession {
        let session = try await get(
            FastmailSession.self, host: Self.fastmailHost, path: "/jmap/session", token: token
        )
        guard session.username.caseInsensitiveCompare(account.address) == .orderedSame else {
            throw ToolkitMailConnectorError.wrongAccount
        }
        let api = session.apiUrl
        guard api.scheme == "https", api.host?.lowercased() == Self.fastmailHost, api.port == nil || api.port == 443,
              api.user == nil, api.password == nil, api.query == nil, api.fragment == nil, api.path.hasPrefix("/jmap/"),
              session.primaryAccounts[Self.jmapMail] != nil else {
            throw ToolkitMailConnectorError.unexpectedResponse
        }
        return session
    }

    func fastmailSearch(
        _ session: FastmailSession, token: String, query: String, limit: Int
    ) async throws -> [ToolkitMailMessage] {
        let accountID = try fastmailAccountID(session)
        let result = try await jmap(
            session, token: token, call: "Email/query",
            parameters: [
                "accountId": accountID, "filter": ["text": query], "limit": limit,
                "sort": [["property": "receivedAt", "isAscending": false]]
            ]
        )
        guard let ids = result["ids"] as? [String] else { throw ToolkitMailConnectorError.unexpectedResponse }
        return try await fastmailMessages(session, token: token, ids: Array(ids.prefix(limit)), includeBody: false)
    }

    func fastmailMessages(
        _ session: FastmailSession, token: String, ids: [String], includeBody: Bool
    ) async throws -> [ToolkitMailMessage] {
        guard !ids.isEmpty else { return [] }
        let accountID = try fastmailAccountID(session)
        let preview = ["id", "subject", "from", "preview", "receivedAt"]
        let result = try await jmap(
            session, token: token, call: "Email/get",
            parameters: [
                "accountId": accountID, "ids": ids,
                "properties": includeBody ? preview + ["textBody", "bodyValues", "attachments"] : preview,
                "bodyProperties": Self.fastmailBodyFields, "fetchTextBodyValues": includeBody, "maxBodyValueBytes": 24_000
            ]
        )
        guard let values = result["list"] as? [[String: Any]] else {
            throw ToolkitMailConnectorError.unexpectedResponse
        }
        return ids.compactMap { identifier in
            guard let message = values.first(where: { $0["id"] as? String == identifier }) else { return nil }
            let name = (message["from"] as? [[String: Any]])?.first?["email"] as? String
            let body = includeBody ? fastmailPlainText(message) : nil
            return ToolkitMailMessage(
                id: identifier, subject: ToolkitRemoteTransport.bounded(message["subject"] as? String, limit: 512),
                from: ToolkitRemoteTransport.bounded(name, limit: 512), preview: ToolkitRemoteTransport.bounded(message["preview"] as? String, limit: 1_024),
                body: body.map { ToolkitRemoteTransport.bounded($0, limit: 24_000) },
                receivedAt: ToolkitRemoteTransport.date(message["receivedAt"] as? String),
                attachments: includeBody
                    ? fastmailAttachmentReferences(message, session: session, scope: accountID + ":" + identifier).map(\.metadata)
                    : []
            )
        }
    }

    func fastmailAttachment(
        _ session: FastmailSession, token: String, id: String, selection: ToolkitMailAttachmentPreviewRequest
    ) async throws -> ToolkitMailAttachmentPreview {
        guard let host = fastmailDownloadHost(session) else { throw ToolkitMailAttachmentPreviewError.unsupported }
        let accountID = try fastmailAccountID(session)
        guard Self.fastmailIsBlobIdentifier(accountID) else { throw ToolkitMailAttachmentPreviewError.unsupported }
        let result = try await jmap(
            session, token: token, call: "Email/get", parameters: [
                "accountId": accountID, "ids": [id], "properties": ["id", "attachments"],
                "bodyProperties": Self.fastmailBodyFields
            ]
        )
        guard let item = (result["list"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id }) else {
            throw ToolkitMailAttachmentPreviewError.changed
        }
        let reference = try MailAttachmentReference.select(
            selection, from: fastmailAttachmentReferences(item, session: session, scope: accountID + ":" + id)
        )
        guard let blobID = reference.id else { throw ToolkitMailAttachmentPreviewError.unsupported }
        // The display name stays local. Use a fixed filename and MIME type when expanding the provider's URL template.
        let download = try request(
            host: host, path: "/jmap/download/" + accountID + "/" + blobID + "/preview.txt",
            token: token, query: [.init(name: "type", value: "text/plain")], headers: ["Accept": "text/plain"]
        )
        return try reference.preview(await attachmentBytes(download, maximum: MailAttachmentReference.maximumBytes))
    }

    private static let fastmailBodyFields = ["partId", "type", "name", "size", "disposition", "blobId"]

    private func fastmailDownloadHost(_ session: FastmailSession) -> String? {
        // Fastmail's official JMAP documentation uses a separate fixed host for content downloads.
        [Self.fastmailHost, "www.fastmailusercontent.com"].first { host in
            session.downloadUrl == "https://\(host)/jmap/download/{accountId}/{blobId}/{name}?type={type}"
        }
    }

    private static func fastmailIsBlobIdentifier(_ id: String) -> Bool {
        (1...255).contains(id.utf8.count) &&
            id.utf8.allSatisfy("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_".utf8.contains)
    }

    func fastmailArchive(_ session: FastmailSession, token: String, id: String) async throws {
        let accountID = try fastmailAccountID(session)
        let mailboxes = try await jmap(
            session, token: token, call: "Mailbox/get", parameters: ["accountId": accountID, "properties": ["id", "role"]]
        )
        let folders = mailboxes["list"] as? [[String: Any]]
        guard let inbox = folders?.first(where: { $0["role"] as? String == "inbox" })?["id"] as? String else {
            throw ToolkitMailConnectorError.unexpectedResponse
        }
        let result = try await jmap(
            session, token: token, call: "Email/get",
            parameters: ["accountId": accountID, "ids": [id], "properties": ["id", "mailboxIds"]]
        )
        guard let item = (result["list"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id }),
              let mailboxIDs = item["mailboxIds"] as? [String: Bool],
              let state = result["state"] as? String else { throw ToolkitMailConnectorError.rejected }
        guard mailboxIDs[inbox] == true else { return }
        var patch: [String: Any] = ["mailboxIds/" + inbox: NSNull()]
        // Keep existing Fastmail labels. The Archive folder is needed if Inbox was the only location.
        if !mailboxIDs.contains(where: { $0.key != inbox && $0.value }) {
            guard let archive = folders?.first(where: { $0["role"] as? String == "archive" })?["id"] as? String,
                  archive != inbox else { throw ToolkitMailConnectorError.unexpectedResponse }
            patch["mailboxIds/" + archive] = true
        }
        let changed = try await jmap(
            session, token: token, call: "Email/set", parameters: ["accountId": accountID, "ifInState": state, "update": [id: patch]]
        )
        guard let updated = changed["updated"] as? [String: Any], updated.keys.contains(id) else {
            throw ToolkitMailConnectorError.rejected
        }
    }

    func fastmailSend(_ session: FastmailSession, token: String, draft: ToolkitMailDraft) async throws {
        let accountID = try fastmailAccountID(session)
        guard session.primaryAccounts[Self.jmapSubmission] == accountID else {
            throw ToolkitMailConnectorError.unauthorized
        }
        let identities = try await jmap(
            session, token: token, call: "Identity/get", parameters: ["accountId": accountID], submission: true
        )
        guard let identity = (identities["list"] as? [[String: Any]])?.first(where: {
            ($0["email"] as? String)?.caseInsensitiveCompare(draft.accountAddress) == .orderedSame
        })?["id"] as? String else {
            throw ToolkitMailConnectorError.wrongAccount
        }
        let mailboxes = try await jmap(
            session, token: token, call: "Mailbox/get", parameters: ["accountId": accountID, "properties": ["id", "role"]]
        )
        let folders = mailboxes["list"] as? [[String: Any]]
        guard let drafts = folders?.first(where: { $0["role"] as? String == "drafts" })?["id"] as? String,
              let sent = folders?.first(where: { $0["role"] as? String == "sent" })?["id"] as? String else {
            throw ToolkitMailConnectorError.unexpectedResponse
        }
        let draftMessage: [String: Any] = [
            "mailboxIds": [drafts: true], "keywords": ["$draft": true],
            "from": [["email": draft.accountAddress]], "to": draft.to.map { ["email": $0] },
            "subject": draft.subject, "textBody": [["partId": "body", "type": "text/plain"]],
            "bodyValues": ["body": ["value": draft.body]],
            "header:X-Aides-Invocation-Id": draft.id.uuidString
        ]
        let accountDraft = try await jmap(
            session, token: token, call: "Email/set",
            parameters: ["accountId": accountID, "create": ["draft": draftMessage]]
        )
        guard let emailID = ((accountDraft["created"] as? [String: [String: Any]])?["draft"])?["id"] as? String else {
            throw ToolkitMailConnectorError.rejected
        }
        let result = try await jmap(
            session, token: token, call: "EmailSubmission/set",
            parameters: [
                "accountId": accountID, "create": ["send": ["identityId": identity, "emailId": emailID]],
                "onSuccessUpdateEmail": [
                    "#send": ["mailboxIds/" + drafts: NSNull(), "mailboxIds/" + sent: true, "keywords/$draft": NSNull()]
                ]
            ], submission: true
        )
        guard (result["created"] as? [String: Any])?["send"] != nil else { throw ToolkitMailConnectorError.rejected }
    }

    private func fastmailAccountID(_ session: FastmailSession) throws -> String {
        guard let id = session.primaryAccounts[Self.jmapMail], !id.isEmpty else {
            throw ToolkitMailConnectorError.unexpectedResponse
        }
        return id
    }

    private func fastmailAttachmentReferences(
        _ message: [String: Any], session: FastmailSession, scope: String
    ) -> [MailAttachmentReference] {
        let parts = message["attachments"] as? [[String: Any]] ?? []
        let canDownload = fastmailDownloadHost(session) != nil
        return parts.prefix(24).compactMap { part in
            guard let name = part["name"] as? String, !name.isEmpty else { return nil }
            let blobID = (part["blobId"] as? String).flatMap {
                canDownload && Self.fastmailIsBlobIdentifier($0) ? $0 : nil
            }
            return MailAttachmentReference(
                id: blobID, scope: "fastmail:" + scope, name: name, type: part["type"] as? String, size: part["size"] as? Int,
                inline: (part["disposition"] as? String)?.lowercased() == "inline"
            )
        }
    }

    private func fastmailPlainText(_ message: [String: Any]) -> String? {
        guard let texts = message["textBody"] as? [[String: Any]],
              let values = message["bodyValues"] as? [String: [String: Any]] else { return nil }
        let parts = texts.compactMap { part -> String? in
            guard part["type"] as? String == "text/plain", let id = part["partId"] as? String else { return nil }
            return values[id]?["value"] as? String
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func jmap(
        _ session: FastmailSession, token: String, call: String, parameters: [String: Any], submission: Bool = false
    ) async throws -> [String: Any] {
        var capabilities = [Self.jmapCore, Self.jmapMail]
        if submission { capabilities.append(Self.jmapSubmission) }
        let payload = try json(["using": capabilities, "methodCalls": [[call, parameters, "request"]]])
        let response = try await object(from: authorizedRequest(url: session.apiUrl, token: token, body: payload))
        guard let responses = response["methodResponses"] as? [[Any]],
              let primary = responses.first, primary.count == 3, primary[2] as? String == "request",
              primary[0] as? String == call, let result = primary[1] as? [String: Any] else {
            throw ToolkitMailConnectorError.unexpectedResponse
        }
        return result
    }
}
