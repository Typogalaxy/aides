import AidesCore
@testable import AidesExecution
import Foundation
import Testing

struct ToolkitGitHubWriteConnectorTests {
    private let repository = ToolkitGitHubRepository(
        id: "repo", owner: "fixture-owner", name: "fixture-repo", label: "Fixture", available: true,
        allowedWrites: [.issue, .pullRequest]
    )

    @Test func submitsIssueAndPullRequestToTheExactRepository() async throws {
        let connector = ToolkitGitHubWriteConnector { request in
            let url = try #require(request.url)
            #expect(url.host == "api.github.com")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let data = try #require(request.httpBody)
            let body = try JSONDecoder().decode([String: String].self, from: data)
            #expect(body["title"] == "A planned change")
            #expect(body["body"] == "Exact user content\n")
            switch url.path {
            case "/repos/fixture-owner/fixture-repo/issues":
                #expect(body["head"] == nil && body["base"] == nil)
                return Data(#"{"number":17,"html_url":"https://malformed.example.org/ignore"}"#.utf8)
            case "/repos/fixture-owner/fixture-repo/pulls":
                #expect(body["head"] == "feature/update")
                #expect(body["base"] == "main")
                return Data(#"{"number":18}"#.utf8)
            default:
                Issue.record("Unexpected GitHub write endpoint: \(url.path)")
                return Data()
            }
        }
        let issue = try await connector.submit(
            ToolkitGitHubWriteRequest(repositoryID: "repo", kind: .issue, title: "A planned change", body: "Exact user content\n"),
            repository: repository, token: "fixture-token"
        )
        #expect(issue.number == 17)
        #expect(issue.url.absoluteString == "https://github.com/fixture-owner/fixture-repo/issues/17")
        let pull = try await connector.submit(
            ToolkitGitHubWriteRequest(
                repositoryID: "repo", kind: .pullRequest, title: "A planned change", body: "Exact user content\n",
                head: "feature/update", base: "main"
            ),
            repository: repository, token: "fixture-token"
        )
        #expect(pull.number == 18)
        #expect(pull.url.absoluteString == "https://github.com/fixture-owner/fixture-repo/pull/18")
    }

    @Test func rejectsCrossRepositoryAndInvalidBranchInputsBeforeDispatch() async {
        let connector = ToolkitGitHubWriteConnector { _ in
            Issue.record("Invalid write reached the transport fixture")
            return Data()
        }
        for invalid in ["upstream:feature", "feature/../other", "refs/heads/hidden", "-switch", "feature.lock", "main"] {
            let request = ToolkitGitHubWriteRequest(
                repositoryID: "repo", kind: .pullRequest, title: "Fixture", body: "", head: invalid, base: "main"
            )
            await #expect(throws: ToolkitRemoteError.rejected) {
                try await connector.submit(request, repository: repository, token: "fixture-token")
            }
        }
        let mismatched = ToolkitGitHubWriteRequest(repositoryID: "other", kind: .issue, title: "Fixture", body: "")
        await #expect(throws: ToolkitRemoteError.rejected) {
            try await connector.submit(mismatched, repository: repository, token: "fixture-token")
        }
    }

    @Test func requiresPositiveWriteReceiptNumber() async {
        let connector = ToolkitGitHubWriteConnector { _ in Data(#"{"number":0}"#.utf8) }
        let request = ToolkitGitHubWriteRequest(repositoryID: "repo", kind: .issue, title: "Fixture", body: "")
        await #expect(throws: ToolkitRemoteError.unexpectedResponse) {
            try await connector.submit(request, repository: repository, token: "fixture-token")
        }
    }
}
