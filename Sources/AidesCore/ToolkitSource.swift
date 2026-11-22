import CryptoKit
import Foundation

public enum ToolkitSourceKind: String, Codable, Sendable {
    case feed, page
}

public struct ToolkitSourceEntry: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let url: String?

    public init(id: String, title: String, url: String?) {
        self.id = id
        self.title = title
        self.url = url
    }
}

public enum ToolkitSourceAddress {
    public static func httpsURL(_ value: String) -> URL? {
        guard (1...2_000).contains(value.utf8.count),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              var address = URLComponents(string: value), address.scheme?.lowercased() == "https",
              let host = address.host?.lowercased(), host.utf8.count <= 253,
              address.user == nil, address.password == nil, address.fragment == nil,
              address.port == nil || address.port == 443 else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, let suffix = labels.last,
              suffix.utf8.contains(where: { (97...122).contains($0) }),
              !["localhost", "local", "test", "invalid", "example", "onion"].contains(suffix),
              !host.hasSuffix(".home.arpa"),
              labels.allSatisfy({ label in
                  (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" &&
                      label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { return nil }
        address.scheme = "https"
        address.host = host
        address.port = nil
        return address.url
    }

    /// Checks a resolved network-order address converted to a host UInt32.
    public static func isPublicIPv4(_ address: UInt32) -> Bool {
        let special: [(base: UInt32, bits: UInt32)] = [
            (0x00000000, 8), (0x0a000000, 8), (0x64400000, 10), (0x7f000000, 8),
            (0xa9fe0000, 16), (0xac100000, 12), (0xc0000000, 24), (0xc0000200, 24),
            (0xc0586300, 24), (0xc0a80000, 16), (0xc6120000, 15), (0xc6336400, 24),
            (0xcb007100, 24), (0xe0000000, 3),
        ]
        return !special.contains { address >> (32 - $0.bits) == $0.base >> (32 - $0.bits) }
    }
}

public enum ToolkitFeedDocument {
    public static let maxBytes = 1_048_576

    public static func entries(_ data: Data) -> [ToolkitSourceEntry]? {
        guard data.count <= maxBytes, !data.contains(0), let xml = String(data: data, encoding: .utf8),
              !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else { return nil }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let receiver = FeedReceiver()
        parser.delegate = receiver
        guard parser.parse(), receiver.recognizedRoot else { return nil }
        return receiver.entries
    }

    public static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class FeedReceiver: NSObject, XMLParserDelegate {
    private struct Draft {
        var id = ""
        var title = ""
        var link = ""
        var depth: Int
    }

    private var path: [String] = []
    private var draft: Draft?
    private var captured: (field: String, depth: Int)?
    private var seen: Set<String> = []
    private(set) var recognizedRoot = false
    private(set) var entries: [ToolkitSourceEntry] = []

    func parser(
        _ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        path.append(element)
        guard path.count <= 48 else {
            parser.abortParsing()
            return
        }
        if path.count == 1 { recognizedRoot = ["rss", "feed", "RDF"].contains(element) }
        if entries.count < 120,
           [["rss", "channel", "item"], ["feed", "entry"], ["RDF", "item"]].contains(path) {
            draft = Draft(depth: path.count)
            return
        }
        guard let depth = draft?.depth, path.count == depth + 1 else { return }
        switch element {
        case "title", "guid", "id":
            captured = (element, path.count)
        case "link":
            if let href = attributes["href"] {
                if attributes["rel"] == nil || attributes["rel"] == "alternate" {
                    draft?.link = String(href.prefix(2_000))
                }
            } else {
                captured = (element, path.count)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let captured, var item = draft else { return }
        switch captured.field {
        case "title": item.title += string.prefix(max(0, 400 - item.title.count))
        case "link": item.link += string.prefix(max(0, 2_000 - item.link.count))
        default: item.id += string.prefix(max(0, 2_000 - item.id.count))
        }
        draft = item
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if let value = String(data: data, encoding: .utf8) { self.parser(parser, foundCharacters: value) }
    }

    func parser(
        _ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?
    ) {
        defer { _ = path.popLast() }
        if captured?.depth == path.count { captured = nil }
        guard let item = draft, item.depth == path.count else { return }
        draft = nil
        let title = item.title
            .split(whereSeparator: { $0.isWhitespace || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
            .joined(separator: " ")
        let entryID = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLink = item.link.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = ToolkitSourceAddress.httpsURL(rawLink)?.absoluteString
        guard !title.isEmpty else { return }
        let fingerprint = ToolkitFeedDocument.fingerprint(Data((!entryID.isEmpty ? entryID : link ?? title).utf8))
        if seen.insert(fingerprint).inserted {
            entries.append(ToolkitSourceEntry(id: fingerprint, title: title, url: link))
        }
    }
}
