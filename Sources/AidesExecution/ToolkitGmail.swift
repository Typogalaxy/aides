import AidesCore
import Foundation

extension ToolkitMailConnector {
    private static let gmailHost = "gmail.googleapis.com"
    private static let gmailMailbox = "/gmail/v1/users/me"

    func checkGmailAccount(_ account: ToolkitMailAccount, token: String) async throws {
        let profile = try await get(
            GmailProfile.self, host: Self.gmailHost, path: Self.gmailMailbox + "/profile", token: token
        )
        guard profile.emailAddress.caseInsensitiveCompare(account.address) == .orderedSame else {
            throw ToolkitMailConnectorError.wrongAccount
        }
    }

    func gmailSearch(token: String, query: String, limit: Int) async throws -> [ToolkitMailMessage] {
        let response = try await get(
            GmailSearch.self, host: Self.gmailHost, path: Self.gmailMailbox + "/messages", token: token,
            query: [.init(name: "q", value: query), .init(name: "maxResults", value: String(limit)),
                    .init(name: "fields", value: "messages(id)")]
        )
        var matches: [ToolkitMailMessage] = []
        for message in (response.messages ?? []).prefix(limit) {
            matches.append(try await gmailMessage(token: token, id: message.id, includeBody: false))
        }
        return matches
    }

    func gmailMessage(token: String, id: String, includeBody: Bool) async throws -> ToolkitMailMessage {
        guard !id.isEmpty, id.utf8.count <= 512, id.utf8.allSatisfy(Self.isOpaqueIdentifierByte) else {
            throw ToolkitMailConnectorError.unexpectedResponse
        }
        let query: [URLQueryItem] = includeBody
            ? [.init(name: "format", value: "full")]
            : [.init(name: "format", value: "metadata"),
               .init(name: "metadataHeaders", value: "From"), .init(name: "metadataHeaders", value: "Subject")]
        let message = try await get(
            GmailMessage.self, host: Self.gmailHost, path: Self.gmailMailbox + "/messages/" + id,
            token: token, query: query
        )
        return ToolkitMailMessage(
            id: message.id, subject: ToolkitRemoteTransport.bounded(message.payload?.header("Subject"), limit: 512),
            from: ToolkitRemoteTransport.bounded(message.payload?.header("From"), limit: 512),
            preview: ToolkitRemoteTransport.bounded(message.snippet, limit: 1_024),
            body: includeBody ? message.payload?.plainText().map { ToolkitRemoteTransport.bounded($0, limit: 24_000) } : nil,
            receivedAt: message.internalDate.flatMap(Int64.init).map { Date(timeIntervalSince1970: Double($0) / 1_000) }
        )
    }

    func gmailSend(token: String, draft: ToolkitMailDraft) async throws {
        let message = Self.gmailWireMessage(draft)
        let raw = Data(message.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try await submit(request(
            host: Self.gmailHost, path: Self.gmailMailbox + "/messages/send", token: token, body: json(["raw": raw])
        ))
    }

    private static func gmailWireMessage(_ draft: ToolkitMailDraft) -> String {
        let delimiter = "\r\n"
        let body = Data(draft.body.utf8).base64EncodedString(options: [.lineLength76Characters])
        let domain = draft.accountAddress.split(separator: "@").last ?? "localhost"
        return [
            "From: \(draft.accountAddress)",
            "To: \(draft.to.joined(separator: ",\r\n "))",
            "Subject: \(encodedSubject(draft.subject))",
            "Message-ID: <\(draft.id.uuidString.lowercased())@\(domain)>",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: base64",
            "", body, ""
        ].joined(separator: delimiter)
    }

    private static func encodedSubject(_ subject: String) -> String {
        var chunks: [Data] = []
        var current = Data()
        for scalar in subject.unicodeScalars {
            let bytes = String(scalar).utf8
            if current.count + bytes.count > 42 {
                chunks.append(current)
                current = Data()
            }
            current.append(contentsOf: bytes)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.map { "=?UTF-8?B?\($0.base64EncodedString())?=" }.joined(separator: "\r\n ")
    }
}

private struct GmailProfile: Decodable {
    let emailAddress: String
}

private struct GmailSearch: Decodable {
    struct Reference: Decodable { let id: String }
    let messages: [Reference]?
}

private struct GmailMessage: Decodable {
    struct Part: Decodable {
        struct Header: Decodable {
            let name: String
            let value: String
        }

        struct Body: Decodable { let data: String? }

        let mimeType: String?
        let filename: String?
        let headers: [Header]?
        let body: Body?
        let parts: [Part]?

        func header(_ name: String) -> String? {
            headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        func plainText(depth: Int = 0) -> String? {
            guard depth <= 8, filename?.isEmpty != false else { return nil }
            if mimeType == "text/plain", let raw = body?.data {
                var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
                return Data(base64Encoded: base64).map { String(decoding: $0, as: UTF8.self) }
            }
            for part in parts ?? [] {
                if let text = part.plainText(depth: depth + 1) { return text }
            }
            return nil
        }
    }

    let id: String
    let snippet: String?
    let internalDate: String?
    let payload: Part?
}
