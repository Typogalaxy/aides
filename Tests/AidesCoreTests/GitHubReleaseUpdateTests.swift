import AidesCore
import Foundation
import Testing

struct GitHubReleaseUpdateTests {
    @Test func choosesNewerNumericVersionWithCompatibleDMG() throws {
        let release = try fixture(tag: "v1.10.0", name: "Aides-1.10.0-arm64-development.dmg")
        let update = try #require(release.update(after: "1.9.2", architecture: "arm64"))
        #expect(update.version == "1.10.0")
        #expect(update.releaseURL.absoluteString == "https://github.com/Typogalaxy/aides/releases/tag/v1.10.0")
        #expect(release.update(after: "1.10.0", architecture: "arm64") == nil)
        #expect(release.update(after: "2.0.0", architecture: "arm64") == nil)
        #expect(release.update(after: "1.9.2", architecture: "x86_64") == nil)
    }

    @Test func ignoresUnpublishedReleasesInvalidTagsAndMissingDMGs() throws {
        for release in [
            try fixture(draft: true),
            try fixture(prerelease: true),
            try fixture(tag: "1.1.0-alpha.1"),
            try fixture(tag: "../1.1.0"),
            try fixture(name: "Aides-1.1.0-arm64.dmg.txt"),
            try fixture(state: "new"),
            try fixture(size: 0),
        ] {
            #expect(release.update(after: "1.0.0", architecture: "arm64") == nil)
        }
        let release = try fixture()
        #expect(release.update(after: "1.0.0", architecture: "arm64")?.version == "1.1.0")
        #expect(release.update(after: "Development", architecture: "arm64") == nil)
    }

    private func fixture(
        tag: String = "1.1.0", name: String = "Aides-1.1.0-arm64.dmg",
        draft: Bool = false, prerelease: Bool = false, state: String = "uploaded", size: Int = 10
    ) throws -> GitHubReleaseUpdate {
        let data = try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "assets": [["name": name, "state": state, "size": size]],
        ])
        return try JSONDecoder().decode(GitHubReleaseUpdate.self, from: data)
    }
}
