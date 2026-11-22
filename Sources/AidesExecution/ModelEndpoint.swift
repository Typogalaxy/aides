import Foundation

extension ModelRequest {
    func modelEndpoint(
        route: String,
        acceptedBases: [String],
        officialHost: String? = nil
    ) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw ModelExecutionError.invalidConfiguration
        }

        if let officialHost {
            guard scheme == "https", host == officialHost,
                  components.port == nil || components.port == 443 else {
                throw ModelExecutionError.invalidConfiguration
            }
        } else {
            guard scheme == "http" || scheme == "https",
                  ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else {
                throw ModelExecutionError.invalidConfiguration
            }
        }

        let path = components.percentEncodedPath
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard normalized == route || acceptedBases.contains(normalized) else {
            throw ModelExecutionError.invalidConfiguration
        }

        components.path = route
        if host == "localhost" { components.host = "127.0.0.1" }
        guard let url = components.url else { throw ModelExecutionError.invalidConfiguration }
        return url
    }
}

struct WireMessage: Encodable {
    let role: String
    let content: String

    init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    init(_ message: ModelMessage) {
        self.init(role: message.role.rawValue, content: message.text)
    }
}

extension ModelClient {
    func post<Input: Encodable, Response: Decodable>(
        _ endpoint: URL,
        payload: Input,
        headers: [String: String] = [:],
        expecting: Response.Type
    ) async throws -> (Response, Int) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let requestBody = try JSONEncoder().encode(payload)
        request.httpBody = requestBody
        let response = try await exchange(request)
        try Task.checkCancellation()
        let body = try ModelTransport.decode(expecting, from: response)
        return (body, requestBody.count + response.body.count)
    }
}
