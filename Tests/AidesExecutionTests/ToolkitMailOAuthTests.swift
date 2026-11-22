import AidesCore
@testable import AidesExecution
import Foundation
import Testing

struct ToolkitMailOAuthTests {
    @Test func gmailRefreshUsesTheFixedHTTPSOriginAndPercentEncodedForm() async throws {
        let broker = ToolkitMailOAuthTokenBroker(exchange: { request in
            #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let data = try #require(request.httpBody)
            let body = String(decoding: data, as: UTF8.self)
            #expect(Set(body.split(separator: "&")) == [
                "grant_type=refresh_token", "client_id=client%2B%26id", "refresh_token=refresh%2B%2F%3D",
                "client_secret=secret%26%3Dvalue",
            ])
            return Data(#"{"access_token":"fixture-access","token_type":"Bearer","expires_in":3600}"#.utf8)
        })
        let token = try await broker.token(
            provider: .gmail, accountID: "fixture",
            credentials: ToolkitMailOAuthCredentials(clientID: "client+&id", refreshToken: "refresh+/=", clientSecret: "secret&=value")
        )
        #expect(token == "fixture-access")
    }

    @Test func outlookCoalescesConcurrentRefreshAndUsesRotatedTokenOnExpiry() async throws {
        let time = MailOAuthFixtureClock()
        let attempts = MailOAuthFixtureAttempts()
        let broker = ToolkitMailOAuthTokenBroker(exchange: { request in
            #expect(request.url?.absoluteString == "https://login.microsoftonline.com/common/oauth2/v2.0/token")
            let data = try #require(request.httpBody)
            let body = String(decoding: data, as: UTF8.self)
            let attempt = await attempts.record()
            if attempt == 1 {
                #expect(body.contains("refresh_token=first-refresh"))
                try await Task.sleep(for: .milliseconds(40))
                return Data(#"{"access_token":"first-access","token_type":"Bearer","expires_in":100,"refresh_token":"rotated-refresh"}"#.utf8)
            }
            #expect(body.contains("refresh_token=rotated-refresh"))
            return Data(#"{"access_token":"second-access","token_type":"Bearer","expires_in":3600}"#.utf8)
        }, now: time.now)
        let credentials = ToolkitMailOAuthCredentials(clientID: "fixture", refreshToken: "first-refresh")
        async let first = broker.token(provider: .outlook, accountID: "fixture", credentials: credentials)
        async let concurrent = broker.token(provider: .outlook, accountID: "fixture", credentials: credentials)
        let tokens = try await [first, concurrent]
        #expect(tokens == ["first-access", "first-access"])
        #expect(await attempts.count == 1)
        time.advance(by: 55)
        let renewed = try await broker.token(provider: .outlook, accountID: "fixture", credentials: credentials)
        #expect(renewed == "second-access")
        #expect(await attempts.count == 2)
    }

    @Test func configReplacementInvalidatesTheCachedTokenAndFastmailCannotRefresh() async throws {
        let attempts = MailOAuthFixtureAttempts()
        let broker = ToolkitMailOAuthTokenBroker(exchange: { _ in
            let attempt = await attempts.record()
            return Data("{\"access_token\":\"access-\(attempt)\",\"token_type\":\"Bearer\",\"expires_in\":3600}".utf8)
        })
        let previous = ToolkitMailOAuthCredentials(clientID: "fixture", refreshToken: "first-refresh")
        let replacement = ToolkitMailOAuthCredentials(clientID: "fixture", refreshToken: "different-refresh")
        let first = try await broker.token(provider: .gmail, accountID: "fixture", credentials: previous)
        let second = try await broker.token(provider: .gmail, accountID: "fixture", credentials: replacement)
        #expect(first == "access-1")
        #expect(second == "access-2")
        await #expect(throws: ToolkitRemoteError.unauthorized) {
            try await broker.token(provider: .fastmail, accountID: "fixture", credentials: previous)
        }
        #expect(await attempts.count == 2)
    }
}

private actor MailOAuthFixtureAttempts {
    private(set) var count = 0

    func record() -> Int {
        count += 1
        return count
    }
}

private final class MailOAuthFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 100)

    func now() -> Date { lock.withLock { current } }

    func advance(by interval: TimeInterval) {
        lock.withLock { current.addTimeInterval(interval) }
    }
}
