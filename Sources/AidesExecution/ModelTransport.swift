import Foundation

struct HTTPPayload: Sendable {
    let statusCode: Int
    let body: Data
}

enum ModelTransport {
    static let maximumResponseBytes = 2 * 1_048_576
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }()

    static func exchange(_ request: URLRequest) async throws -> HTTPPayload {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw ModelExecutionError.unexpectedResponse
            }

            // Do not retain upstream error bodies. They may contain request details.
            guard response.statusCode == 200 else {
                bytes.task.cancel()
                return HTTPPayload(statusCode: response.statusCode, body: Data())
            }

            guard response.expectedContentLength <= maximumResponseBytes else {
                bytes.task.cancel()
                throw ModelExecutionError.outputLimit
            }

            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else {
                    bytes.task.cancel()
                    throw ModelExecutionError.outputLimit
                }
                data.append(byte)
            }
            return HTTPPayload(statusCode: response.statusCode, body: data)
        } catch let error as ModelExecutionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw ModelExecutionError.unavailable
        }
    }

    static func decode<Response: Decodable>(_ type: Response.Type, from payload: HTTPPayload) throws -> Response {
        switch payload.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(type, from: payload.body)
            } catch {
                throw ModelExecutionError.unexpectedResponse
            }
        case 401, 403:
            throw ModelExecutionError.unauthorized
        case 429:
            throw ModelExecutionError.rateLimited
        case 408, 425, 500...599:
            throw ModelExecutionError.unavailable
        case 400...499:
            throw ModelExecutionError.rejected
        default:
            throw ModelExecutionError.unexpectedResponse
        }
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
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
