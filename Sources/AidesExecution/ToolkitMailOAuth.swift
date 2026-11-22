import AidesCore
import CryptoKit
import Foundation

public struct ToolkitMailOAuthCredentials: Decodable, Sendable {
    let clientID: String
    let refreshToken: String
    let clientSecret: String?

    public init(clientID: String, refreshToken: String, clientSecret: String? = nil) {
        self.clientID = clientID
        self.refreshToken = refreshToken
        self.clientSecret = clientSecret
    }

    public var isValid: Bool {
        Self.isCompactASCII(clientID, limit: 1_024) && Self.isCompactASCII(refreshToken, limit: 16_384) &&
            (clientSecret.map { Self.isCompactASCII($0, limit: 4_096) } ?? true)
    }

    fileprivate var fingerprint: SHA256.Digest {
        // Visible ASCII validation prevents delimiter collisions.
        SHA256.hash(data: Data([clientID, refreshToken, clientSecret ?? ""].joined(separator: "\n").utf8))
    }

    fileprivate static func isCompactASCII(_ value: String, limit: Int) -> Bool {
        (1...limit).contains(value.utf8.count) && value.utf8.allSatisfy { (33...126).contains($0) }
    }
}

public enum ToolkitMailOAuthError: Error, Equatable, Sendable {
    case reauthorizationRequired
}

public actor ToolkitMailOAuthTokenBroker {
    public static let shared = ToolkitMailOAuthTokenBroker()

    private struct Grant: Decodable, Sendable {
        let accessToken: String
        let tokenType: String
        let expiresIn: Int
        let refreshToken: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    private struct CachedToken: Sendable {
        let accessToken: String
        let refreshToken: String
        let renewAt: Date
    }

    private struct Flight: Sendable {
        let id: UUID
        let request: Task<CachedToken, Error>
    }

    private struct Entry: Sendable {
        let fingerprint: SHA256.Digest
        var cached: CachedToken?
        var flight: Flight?
    }

    private let exchange: @Sendable (URLRequest) async throws -> Data
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]

    private init() {
        exchange = { request in
            try await ToolkitRemoteTransport.exchange(
                request, allowedHosts: ["oauth2.googleapis.com", "login.microsoftonline.com"], maximumBytes: 49_152
            )
        }
        now = { .now }
    }

    init(exchange: @escaping @Sendable (URLRequest) async throws -> Data, now: @escaping @Sendable () -> Date = { .now }) {
        self.exchange = exchange
        self.now = now
    }

    public func token(
        provider: ToolkitMailProvider, accountID: String, credentials: ToolkitMailOAuthCredentials
    ) async throws -> String {
        guard credentials.isValid, provider != .fastmail else { throw ToolkitRemoteError.unauthorized }
        let key = provider.rawValue + ":" + accountID
        let fingerprint = credentials.fingerprint
        let entry = entries[key].flatMap { $0.fingerprint == fingerprint ? $0 : nil }
        if let cached = entry?.cached, cached.renewAt > now() { return cached.accessToken }
        if let flight = entry?.flight { return try await flight.request.value.accessToken }

        let previous = entry?.cached?.refreshToken ?? credentials.refreshToken
        let request = try Self.request(provider: provider, credentials: credentials, refreshToken: previous)
        let exchange = self.exchange
        let now = self.now
        let flight = Flight(id: UUID(), request: Task {
            let data: Data
            do {
                data = try await exchange(request)
            } catch ToolkitRemoteError.unauthorized {
                throw ToolkitMailOAuthError.reauthorizationRequired
            } catch ToolkitRemoteError.rejected {
                throw ToolkitMailOAuthError.reauthorizationRequired
            }
            guard data.count <= 49_152,
                  let grant = try? JSONDecoder().decode(Grant.self, from: data),
                  grant.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
                  ToolkitMailOAuthCredentials.isCompactASCII(grant.accessToken, limit: 16_384),
                  (1...604_800).contains(grant.expiresIn) else {
                throw ToolkitRemoteError.unexpectedResponse
            }
            let renewalToken = grant.refreshToken.flatMap {
                ToolkitMailOAuthCredentials.isCompactASCII($0, limit: 16_384) ? $0 : nil
            } ?? previous
            let lifetime = TimeInterval(grant.expiresIn)
            return CachedToken(
                accessToken: grant.accessToken, refreshToken: renewalToken,
                renewAt: now().addingTimeInterval(lifetime - min(60, lifetime / 2))
            )
        })
        entries[key] = Entry(fingerprint: fingerprint, cached: entry?.cached, flight: flight)
        do {
            let cached = try await flight.request.value
            if entries[key]?.flight?.id == flight.id {
                entries[key] = Entry(fingerprint: fingerprint, cached: cached, flight: nil)
            }
            return cached.accessToken
        } catch {
            if entries[key]?.flight?.id == flight.id { entries[key]?.flight = nil }
            throw error
        }
    }

    private static func request(
        provider: ToolkitMailProvider, credentials: ToolkitMailOAuthCredentials, refreshToken: String
    ) throws -> URLRequest {
        let target: String
        switch provider {
        case .gmail:
            target = "https://oauth2.googleapis.com/token"
        case .outlook:
            target = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        case .fastmail:
            throw ToolkitRemoteError.unauthorized
        }
        guard let endpoint = URL(string: target) else { throw ToolkitRemoteError.unexpectedResponse }
        var fields = [
            ("grant_type", "refresh_token"),
            ("client_id", credentials.clientID),
            ("refresh_token", refreshToken)
        ]
        if let secret = credentials.clientSecret { fields.append(("client_secret", secret)) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let form = try fields.map { field -> String in
            guard let encoded = field.1.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw ToolkitRemoteError.unexpectedResponse
            }
            return field.0 + "=" + encoded
        }.joined(separator: "&")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(form.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
