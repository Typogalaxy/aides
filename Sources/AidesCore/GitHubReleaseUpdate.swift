import Foundation

public struct GitHubReleaseUpdate: Decodable, Sendable {
    private struct Asset: Decodable, Sendable {
        let name: String
        let state: String
        let size: Int
    }

    private let tag: String
    private let draft: Bool
    private let prerelease: Bool
    private let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case draft, prerelease, assets
    }

    public struct Available: Equatable, Sendable {
        public let version: String
        public let releaseURL: URL
    }

    public func update(after installedVersion: String, architecture: String) -> Available? {
        guard !draft, !prerelease, let release = Version(tag), let installed = Version(installedVersion),
              installed < release else { return nil }
        let version = release.description
        let prefix = "Aides-\(version)-\(architecture)"
        guard assets.contains(where: { asset in
            asset.state == "uploaded" && asset.size > 0 &&
                (asset.name == "\(prefix).dmg" || asset.name == "\(prefix)-development.dmg")
        }) else { return nil }
        // Construct the link from the validated release tag and the known repository.
        let releaseURL = URL(string: "https://github.com/Typogalaxy/aides/releases/tag/")!.appending(path: tag)
        return Available(version: version, releaseURL: releaseURL)
    }

    public static func supports(installedVersion: String) -> Bool {
        Version(installedVersion) != nil
    }

    private struct Version: Comparable, CustomStringConvertible {
        let parts: [UInt32]

        init?(_ raw: String) {
            let version = raw.first == "v" ? raw.dropFirst() : raw[...]
            let segments = version.split(separator: ".", omittingEmptySubsequences: false)
            guard segments.count == 3 else { return nil }
            let parts = segments.compactMap { UInt32($0) }
            guard parts.count == 3, zip(parts, segments).allSatisfy({ String($0.0) == $0.1 }) else { return nil }
            self.parts = parts
        }

        var description: String { parts.map(String.init).joined(separator: ".") }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.parts.lexicographicallyPrecedes(rhs.parts)
        }
    }
}
