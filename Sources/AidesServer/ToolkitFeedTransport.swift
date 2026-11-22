import AidesCore
import AsyncHTTPClient
import Darwin
import Foundation

enum ToolkitFeedError: String, Error, Sendable {
    case address = "The source had no eligible public IPv4 address."
    case status = "The public source did not return a successful response."
    case invalidFeed = "The response was not a supported UTF-8 RSS or Atom feed."
    case unavailable = "The public source could not be reached or exceeded the response limit."
}

enum ToolkitFeedTransport {
    static func fetch(_ raw: String, kind: ToolkitSourceKind) async throws -> Data {
        guard let url = ToolkitSourceAddress.httpsURL(raw), let host = url.host,
              let address = await Task.detached(priority: .utility, operation: { pinnedAddress(for: host) }).value else {
            throw ToolkitFeedError.address
        }
        try Task.checkCancellation()

        var configuration = HTTPClient.Configuration()
        configuration.redirectConfiguration = .disallow
        configuration.dnsOverride = [host: address]
        configuration.proxy = nil
        configuration.timeout = .init(connect: .seconds(4), read: .seconds(5))
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
        do {
            var request = HTTPClientRequest(url: url.absoluteString)
            request.headers.add(
                name: "Accept",
                value: kind == .feed ? "application/rss+xml, application/atom+xml, application/xml, text/xml" : "text/html, text/plain"
            )
            let response = try await client.execute(request, timeout: .seconds(12))
            guard response.status == .ok else { throw ToolkitFeedError.status }
            let payload = try await response.body.collect(upTo: ToolkitFeedDocument.maxBytes)
            try await client.shutdown().get()
            return Data(payload.readableBytesView)
        } catch {
            try? await client.shutdown().get()
            throw error
        }
    }

    private static func pinnedAddress(for host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var answer: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &answer) == 0, let first = answer else { return nil }
        defer { freeaddrinfo(first) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        while let candidate = current {
            defer { current = candidate.pointee.ai_next }
            guard let socket = candidate.pointee.ai_addr, candidate.pointee.ai_addrlen >= MemoryLayout<sockaddr_in>.size else {
                continue
            }
            let bits = socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            guard ToolkitSourceAddress.isPublicIPv4(bits) else { continue }
            let octets = [bits >> 24, (bits >> 16) & 255, (bits >> 8) & 255, bits & 255]
            return octets.map(String.init).joined(separator: ".")
        }
        return nil
    }
}
