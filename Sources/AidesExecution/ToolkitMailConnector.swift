import AidesCore
import Foundation

public typealias ToolkitMailConnectorError = ToolkitRemoteError

public struct ToolkitMailConnector: Sendable {
    private let exchange: @Sendable (URLRequest) async throws -> Data

    public init() {
        exchange = { request in
            try await ToolkitRemoteTransport.exchange(
                request, allowedHosts: ["gmail.googleapis.com", "graph.microsoft.com", "api.fastmail.com"]
            )
        }
    }

    init(exchange: @escaping @Sendable (URLRequest) async throws -> Data) {
        self.exchange = exchange
    }

    public func search(
        account: ToolkitMailAccount, token: String, query: String, limit: Int
    ) async throws -> [ToolkitMailMessage] {
        switch account.provider {
        case .gmail:
            try await checkGmailAccount(account, token: token)
            return try await gmailSearch(token: token, query: query, limit: limit)
        case .outlook:
            try await checkOutlookAccount(account, token: token)
            return try await outlookSearch(token: token, query: query, limit: limit)
        case .fastmail:
            let session = try await fastmailSession(account, token: token)
            return try await fastmailSearch(session, token: token, query: query, limit: limit)
        }
    }

    public func read(
        account: ToolkitMailAccount, token: String, messageID: String
    ) async throws -> ToolkitMailMessage {
        guard !messageID.isEmpty, messageID.utf8.count <= 512,
              messageID.utf8.allSatisfy(Self.isOpaqueIdentifierByte) else {
            throw ToolkitMailConnectorError.rejected
        }
        switch account.provider {
        case .gmail:
            try await checkGmailAccount(account, token: token)
            return try await gmailMessage(token: token, id: messageID, includeBody: true)
        case .outlook:
            try await checkOutlookAccount(account, token: token)
            return try await outlookMessage(token: token, id: messageID)
        case .fastmail:
            let session = try await fastmailSession(account, token: token)
            guard let message = try await fastmailMessages(session, token: token, ids: [messageID], includeBody: true).first else {
                throw ToolkitMailConnectorError.rejected
            }
            return message
        }
    }

    public func send(
        draft: ToolkitMailDraft, account: ToolkitMailAccount, token: String
    ) async throws {
        switch account.provider {
        case .gmail:
            try await checkGmailAccount(account, token: token)
            try await gmailSend(token: token, draft: draft)
        case .outlook:
            try await checkOutlookAccount(account, token: token)
            try await outlookSend(token: token, draft: draft)
        case .fastmail:
            let session = try await fastmailSession(account, token: token)
            try await fastmailSend(session, token: token, draft: draft)
        }
    }

    static func isOpaqueIdentifierByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || [43, 45, 61, 95, 126].contains(byte)
    }

    func get<Response: Decodable>(
        _ type: Response.Type, host: String, path: String, token: String,
        query: [URLQueryItem] = [], headers: [String: String] = [:]
    ) async throws -> Response {
        try await decode(type, from: request(host: host, path: path, token: token, query: query, headers: headers))
    }

    func request(
        host: String, path: String, token: String, query: [URLQueryItem] = [],
        headers: [String: String] = [:], body: Data? = nil
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw ToolkitMailConnectorError.unexpectedResponse }
        return authorizedRequest(url: url, token: token, headers: headers, body: body)
    }

    func authorizedRequest(
        url: URL, token: String, headers: [String: String] = [:], body: Data? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func decode<Response: Decodable>(_ type: Response.Type, from request: URLRequest) async throws -> Response {
        let data = try await exchange(request)
        guard let response = try? JSONDecoder().decode(type, from: data) else {
            throw ToolkitMailConnectorError.unexpectedResponse
        }
        return response
    }

    func submit(_ request: URLRequest) async throws {
        _ = try await exchange(request)
    }

    func json(_ object: [String: Any]) throws -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            throw ToolkitMailConnectorError.unexpectedResponse
        }
        return data
    }

    func object(from request: URLRequest) async throws -> [String: Any] {
        let data = try await exchange(request)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ToolkitMailConnectorError.unexpectedResponse
        }
        return object
    }
}
