import Foundation
import Testing
@testable import AidesExecution

struct CodingReviewTests {
    @Test(arguments: [CodingReviewProvider.codex, .claudeCode])
    func onlyPassesApprovedMaterialViaStandardInput(provider: CodingReviewProvider) async throws {
        let checks: String
        switch provider {
        case .codex:
            checks = """
                contains --ignore-user-config
                contains --strict-config
                contains --ephemeral
                contains 'permissions.aides_report.filesystem={}'
                contains 'permissions.aides_report.network.enabled=false'
                contains shell_tool
                """
        case .claudeCode:
            checks = """
                contains --restricted
                contains --safe-mode
                contains --disallowedTools
                contains '*'
                contains --no-session-persistence
                """
        }

        let executable = try Fixture("""
            #!/bin/sh
            set -eu
            test -z "$(ls -A)"
            test -z "${OPENAI_API_KEY:-}"
            test -z "${ANTHROPIC_API_KEY:-}"
            case "$*" in *'safe excerpt'*) exit 1 ;; esac
            contains() { case "$arguments" in *"$1"*) ;; *) exit 1 ;; esac; }
            arguments="$*"
            \(checks)
            printf '%s' 'Review: '
            /bin/cat
            """)

        let output = try await CodingReviewClient().generate(CodingReviewRequest(
            provider: provider,
            executable: executable.url,
            model: "example",
            approvedInput: "safe excerpt"
        ))

        #expect(output.text == "Review: safe excerpt")
        #expect(output.inputTokens == nil)
    }

    @Test func capsSubprocessOutput() async throws {
        let executable = try Fixture("""
            #!/bin/sh
            exec /usr/bin/yes
            """)
        let client = CodingReviewClient(timeout: .seconds(20))

        await #expect(throws: ModelExecutionError.outputLimit) {
            try await client.generate(CodingReviewRequest(
                provider: .codex, executable: executable.url, model: "example", approvedInput: "safe"
            ))
        }
    }

    @Test func timesOutUnresponsiveSubprocess() async throws {
        let executable = try Fixture("""
            #!/bin/sh
            exec /bin/sleep 30
            """)
        let client = CodingReviewClient(timeout: .milliseconds(250))

        await #expect(throws: ModelExecutionError.unavailable) {
            try await client.generate(CodingReviewRequest(
                provider: .codex, executable: executable.url, model: "example", approvedInput: "safe"
            ))
        }
    }

    @Test func rejectsModelNamesThatCouldBeOptions() async throws {
        let executable = try Fixture("""
            #!/bin/sh
            exit 0
            """)

        await #expect(throws: ModelExecutionError.invalidConfiguration) {
            try await CodingReviewClient().generate(CodingReviewRequest(
                provider: .codex, executable: executable.url, model: "--enable", approvedInput: "safe"
            ))
        }
    }
}

private final class Fixture {
    let url: URL

    init(_ script: String) throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "aides-review-fixture-\(UUID().uuidString)")
        let created = FileManager.default.createFile(
            atPath: url.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]
        )
        guard created else { throw CocoaError(.fileWriteUnknown) }
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
