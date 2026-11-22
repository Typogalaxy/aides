import Foundation
import Security

struct ServerEndpoint: Sendable {
    static let localAddress = "http://127.0.0.1:8317"

    let url: URL

    init(_ address: String) throws {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { throw ServerError.invalidAddress }

        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard components.scheme == "https" || (components.scheme == "http" && loopback) else {
            throw ServerError.insecureAddress
        }
        components.path = ""
        guard let url = components.url else { throw ServerError.invalidAddress }
        self.url = url
    }
}

enum ServerError: LocalizedError {
    case invalidAddress
    case insecureAddress
    case invalidResponse
    case response(status: Int, message: String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "Enter a server address with its scheme and port, such as \(ServerEndpoint.localAddress)."
        case .insecureAddress:
            "Remote server addresses require HTTPS."
        case .invalidResponse:
            "The server returned an unreadable response. Check that your client and server versions match."
        case let .response(_, message):
            message
        case let .keychain(status):
            "The device credential could not be saved or read in Keychain (\(status))."
        }
    }

    var isUnauthorized: Bool {
        if case .response(401, _) = self { return true }
        return false
    }
}

struct AccountCredential: Codable, Sendable {
    let token: String
    let deviceID: UUID
}

private struct ErrorResponse: Decodable & Sendable {
    let error: String?
    let reason: String?
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct ServerClient: Sendable {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 45
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    let endpoint: ServerEndpoint
    var credential: AccountCredential? = nil

    func get<Response: Decodable & Sendable>(
        _ route: [String], query: [URLQueryItem] = []
    ) async throws -> Response {
        try await request("GET", route: route, query: query)
    }

    func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ route: [String], body: Body
    ) async throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try await request("POST", route: route, body: encoder.encode(body))
    }

    func delete<Response: Decodable & Sendable>(_ route: [String]) async throws -> Response {
        try await request("DELETE", route: route)
    }

    private func request<Response: Decodable & Sendable>(
        _ method: String, route: [String], query: [URLQueryItem] = [], body: Data? = nil
    ) async throws -> Response {
        let url = (["api", "v1"] + route).reduce(endpoint.url) {
            $0.appendingPathComponent($1)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ServerError.invalidAddress
        }
        if !query.isEmpty { components.queryItems = query }
        guard let address = components.url else { throw ServerError.invalidAddress }
        var request = URLRequest(url: address)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if let credential {
            request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServerError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date")
        }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? decoder.decode(ErrorResponse.self, from: data)
            throw ServerError.response(
                status: http.statusCode,
                message: error?.error ?? error?.reason ?? "The server returned status \(http.statusCode)."
            )
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw ServerError.invalidResponse
        }
    }
}

enum CredentialStore {
    private static let store = LocalKeychain(service: "org.typogalaxy.aides.device")

    static func read(for endpoint: ServerEndpoint) throws -> AccountCredential? {
        guard let data = try store.read(account: endpoint.url.absoluteString) else { return nil }
        return try JSONDecoder().decode(AccountCredential.self, from: data)
    }

    static func save(_ credential: AccountCredential, for endpoint: ServerEndpoint) throws {
        try store.save(JSONEncoder().encode(credential), account: endpoint.url.absoluteString)
    }

    static func delete(for endpoint: ServerEndpoint) throws {
        try store.delete(account: endpoint.url.absoluteString)
    }
}

struct LocalKeychain {
    let service: String

    private func item(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(account: String) throws -> Data? {
        var query = item(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ServerError.keychain(status)
        }
        return data
    }

    func save(_ data: Data, account: String) throws {
        let query = item(account: account)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(update) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ServerError.keychain(status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(item(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ServerError.keychain(status)
        }
    }
}
