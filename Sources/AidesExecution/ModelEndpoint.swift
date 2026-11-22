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
    let images: [Data]?

    init(role: String, content: String, images: [Data]? = nil) {
        self.role = role
        self.content = content
        self.images = images
    }

    init(_ message: ModelMessage) {
        self.init(
            role: message.role.rawValue,
            content: message.text,
            images: message.images.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

extension ModelClient {
    func post<Input: Encodable, Response: Decodable>(
        _ endpoint: URL,
        payload: Input,
        headers: [String: String] = [:],
        expecting: Response.Type
    ) async throws -> (Response, Int) {
        let request = try modelPOST(endpoint, payload: payload, headers: headers)
        let response = try await exchange(request)
        try Task.checkCancellation()
        let body = try ModelTransport.decode(expecting, from: response)
        return (body, (request.httpBody?.count ?? 0) + response.body.count)
    }

    func modelPOST<Input: Encodable>(
        _ endpoint: URL, payload: Input, headers: [String: String], accept: String = "application/json"
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }
}
