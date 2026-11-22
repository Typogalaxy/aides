import AidesCore
import Foundation

public struct ToolkitGitHubConnector: Sendable {
    private let exchange: @Sendable (URLRequest) async throws -> Data

    public init() {
        exchange = { request in
            try await ToolkitRemoteTransport.exchange(request, allowedHosts: ["api.github.com"])
        }
    }

    init(exchange: @escaping @Sendable (URLRequest) async throws -> Data) {
        self.exchange = exchange
    }

    public func items(
        repository: ToolkitGitHubRepository, token: String?, kind: ToolkitGitHubItemKind, limit: Int
    ) async throws -> [ToolkitGitHubItem] {
        guard Self.isPathComponent(repository.owner), Self.isPathComponent(repository.name),
              (1...20).contains(limit) else { throw ToolkitRemoteError.rejected }

        var address = URLComponents()
        address.scheme = "https"
        address.host = "api.github.com"
        let repositoryPath = "/repos/\(repository.owner)/\(repository.name)"
        switch kind {
        case .issues:
            address.path = repositoryPath + "/issues"
        case .pullRequests:
            address.path = repositoryPath + "/pulls"
        case .workflowRuns:
            address.path = repositoryPath + "/actions/runs"
        }
        // The issues API also includes pull requests. Fetch a bounded larger page and filter those locally.
        let pageLimit = kind == .issues ? min(limit * 2, 30) : limit
        address.queryItems = [.init(name: "per_page", value: String(pageLimit))]
        if kind != .workflowRuns {
            address.queryItems?.append(contentsOf: [
                .init(name: "state", value: "all"), .init(name: "sort", value: "updated"),
                .init(name: "direction", value: "desc")
            ])
        }
        guard let url = address.url else { throw ToolkitRemoteError.unexpectedResponse }
        var request = URLRequest(url: url)
        request.setValue(
            kind == .workflowRuns ? "application/vnd.github+json" : "application/vnd.github.text+json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Aides-Toolkit", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let data = try await exchange(request)
        let decoder = JSONDecoder()
        do {
            switch kind {
            case .issues, .pullRequests:
                let records = try decoder.decode([GitHubDiscussion].self, from: data)
                return records.lazy.filter { kind != .issues || $0.pullRequest == nil }.prefix(limit).map { record in
                    try record.item(repository: repository, kind: kind)
                }
            case .workflowRuns:
                return try decoder.decode(GitHubWorkflowRuns.self, from: data).runs.prefix(limit).map { run in
                    try run.item(repository: repository)
                }
            }
        } catch {
            throw ToolkitRemoteError.unexpectedResponse
        }
    }

    private static func isPathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 100 &&
            value.utf8.allSatisfy("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-".utf8.contains)
    }
}

private struct GitHubDiscussion: Decodable {
    struct PullReference: Decodable {}

    let id: Int64
    let number: Int
    let title: String
    let bodyText: String?
    let state: String
    let updatedAt: String?
    let pullRequest: PullReference?

    private enum CodingKeys: String, CodingKey {
        case id, number, title, state
        case bodyText = "body_text"
        case updatedAt = "updated_at"
        case pullRequest = "pull_request"
    }

    func item(repository: ToolkitGitHubRepository, kind: ToolkitGitHubItemKind) throws -> ToolkitGitHubItem {
        let collection = kind == .issues ? "issues" : "pull"
        return ToolkitGitHubItem(
            id: String(id), number: number,
            title: ToolkitRemoteTransport.bounded(title, limit: 512),
            summary: bodyText.map { ToolkitRemoteTransport.bounded($0, limit: 4_096) },
            state: ToolkitRemoteTransport.bounded(state, limit: 80),
            url: try githubPage(repository, collection + "/\(number)"),
            updatedAt: ToolkitRemoteTransport.date(updatedAt)
        )
    }
}

private struct GitHubWorkflowRuns: Decodable {
    struct Run: Decodable {
        let id: Int64
        let runNumber: Int
        let name: String?
        let displayTitle: String?
        let status: String
        let conclusion: String?
        let updatedAt: String?

        private enum CodingKeys: String, CodingKey {
            case id, name, status, conclusion
            case runNumber = "run_number"
            case displayTitle = "display_title"
            case updatedAt = "updated_at"
        }

        func item(repository: ToolkitGitHubRepository) throws -> ToolkitGitHubItem {
            ToolkitGitHubItem(
                id: String(id), number: runNumber,
                title: ToolkitRemoteTransport.bounded(displayTitle ?? name ?? "Workflow run", limit: 512),
                summary: name.map { ToolkitRemoteTransport.bounded($0, limit: 1_024) },
                state: ToolkitRemoteTransport.bounded(conclusion ?? status, limit: 80),
                url: try githubPage(repository, "actions/runs/\(id)"),
                updatedAt: ToolkitRemoteTransport.date(updatedAt)
            )
        }
    }

    let runs: [Run]
    private enum CodingKeys: String, CodingKey { case runs = "workflow_runs" }
}

private func githubPage(_ repository: ToolkitGitHubRepository, _ path: String) throws -> URL {
    guard let url = URL(string: "https://github.com/\(repository.owner)/\(repository.name)/" + path) else {
        throw ToolkitRemoteError.unexpectedResponse
    }
    return url
}
