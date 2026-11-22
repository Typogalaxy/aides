import AidesCore
@testable import AidesExecution
import Foundation
import Testing

struct ToolkitGitHubConnectorTests {
    @Test func listsIssuesPullsAndRunsFromTheGrantedRepository() async throws {
        let repository = ToolkitGitHubRepository(
            id: "repo", owner: "fixture-owner", name: "fixture-repo", label: "Fixture", available: true
        )
        let connector = ToolkitGitHubConnector { request in
            let url = try #require(request.url)
            #expect(url.host == "api.github.com")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10")
            switch url.path {
            case "/repos/fixture-owner/fixture-repo/issues":
                return Data(#"[{"id":100,"number":1,"title":"Real issue","body_text":"Preview","state":"open","updated_at":"2026-11-22T01:00:00Z"},{"id":101,"number":2,"title":"Actually a PR","state":"open","pull_request":{}}]"#.utf8)
            case "/repos/fixture-owner/fixture-repo/pulls":
                return Data(#"[{"id":101,"number":2,"title":"PR title","state":"closed"}]"#.utf8)
            case "/repos/fixture-owner/fixture-repo/actions/runs":
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
                return Data(#"{"workflow_runs":[{"id":999,"run_number":5,"display_title":"CI","name":"Build","status":"completed","conclusion":"success"}]}"#.utf8)
            default:
                Issue.record("Unexpected GitHub fixture endpoint: \(url.path)")
                return Data()
            }
        }
        let issues = try await connector.items(repository: repository, token: "fixture-token", kind: .issues, limit: 10)
        #expect(issues.map(\.title) == ["Real issue"])
        #expect(issues.first?.summary == "Preview")
        #expect(issues.first?.url.absoluteString == "https://github.com/fixture-owner/fixture-repo/issues/1")
        #expect(issues.first?.updatedAt != nil)
        let pulls = try await connector.items(repository: repository, token: "fixture-token", kind: .pullRequests, limit: 10)
        #expect(pulls.first?.url.absoluteString == "https://github.com/fixture-owner/fixture-repo/pull/2")
        let runs = try await connector.items(repository: repository, token: "fixture-token", kind: .workflowRuns, limit: 10)
        #expect(runs.first?.state == "success")
        #expect(runs.first?.url.absoluteString == "https://github.com/fixture-owner/fixture-repo/actions/runs/999")
    }

    @Test func rejectsUnsafeRepositoryPathBeforeConnecting() async throws {
        let repository = ToolkitGitHubRepository(
            id: "repo", owner: "fixture/other", name: "fixture-repo", label: "Fixture", available: true
        )
        let connector = ToolkitGitHubConnector { _ in
            Issue.record("Unsafe repository path reached the transport")
            return Data()
        }
        await #expect(throws: ToolkitRemoteError.rejected) {
            try await connector.items(repository: repository, token: "fixture-token", kind: .issues, limit: 10)
        }
    }
}
