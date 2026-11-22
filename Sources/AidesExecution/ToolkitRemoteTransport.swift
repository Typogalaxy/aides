import Foundation

public enum ToolkitRemoteError: Error, Equatable, Sendable {
    case unauthorized, unavailable, unexpectedResponse, wrongAccount, rejected, outputLimit
}

enum ToolkitRemoteTransport {
    private static let maximumResponseBytes = 2 * 1_048_576
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: ToolkitRemoteRefuseRedirects(), delegateQueue: nil)
    }()

    static func bounded(_ text: String?, limit: Int) -> String {
        guard let text, limit > 0 else { return "" }
        let bytes = text.utf8
        guard bytes.count > limit else { return text }
        var end = bytes.index(bytes.startIndex, offsetBy: limit)
        while bytes[end] & 0b1100_0000 == 0b1000_0000 {
            end = bytes.index(before: end)
        }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    static func exchange(
        _ request: URLRequest, allowedHosts: Set<String>, maximumBytes: Int = maximumResponseBytes
    ) async throws -> Data {
        guard let url = request.url, let host = url.host?.lowercased(), allowedHosts.contains(host),
              url.scheme == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw ToolkitRemoteError.rejected
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw ToolkitRemoteError.unexpectedResponse
            }
            guard (200...299).contains(http.statusCode) else {
                bytes.task.cancel()
                switch http.statusCode {
                case 401, 403: throw ToolkitRemoteError.unauthorized
                case 408, 429, 500...599: throw ToolkitRemoteError.unavailable
                default: throw ToolkitRemoteError.rejected
                }
            }
            guard http.expectedContentLength <= maximumBytes else {
                bytes.task.cancel()
                throw ToolkitRemoteError.outputLimit
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else {
                    bytes.task.cancel()
                    throw ToolkitRemoteError.outputLimit
                }
                data.append(byte)
            }
            return data
        } catch let error as ToolkitRemoteError {
            throw error
        } catch {
            throw ToolkitRemoteError.unavailable
        }
    }
}

private final class ToolkitRemoteRefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
