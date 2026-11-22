import AidesCore
import Foundation

public struct ToolkitGitHubWriteResult: Sendable {
    public let number: Int
    public let url: URL
}

public struct ToolkitGitHubWriteConnector: Sendable {
    private let exchange: @Sendable (URLRequest) async throws -> Data

    public init() {
        exchange = { request in
            try await ToolkitRemoteTransport.exchange(request, allowedHosts: ["api.github.com"])
        }
    }

    init(exchange: @escaping @Sendable (URLRequest) async throws -> Data) {
        self.exchange = exchange
    }

    public func submit(
        _ input: ToolkitGitHubWriteRequest, repository: ToolkitGitHubRepository, token: String
    ) async throws -> ToolkitGitHubWriteResult {
        guard input.isValid, input.repositoryID == repository.id, !token.isEmpty,
              repository.available, repository.allowedWrites?.contains(input.kind) == true,
              ToolkitGitHubConnector.isPathComponent(repository.owner),
              ToolkitGitHubConnector.isPathComponent(repository.name) else {
            throw ToolkitRemoteError.rejected
        }
        let collection = input.kind == .issue ? "issues" : "pulls"
        let repoPath = "\(repository.owner)/\(repository.name)"
        guard let url = URL(string: "https://api.github.com/repos/\(repoPath)/\(collection)") else {
            throw ToolkitRemoteError.rejected
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Aides-Toolkit", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Payload(
            title: input.title, body: input.body, head: input.head, base: input.base
        ))

        let data = try await exchange(request)
        guard let created = try? JSONDecoder().decode(Receipt.self, from: data), created.number > 0 else {
            throw ToolkitRemoteError.unexpectedResponse
        }
        let collectionPath = input.kind == .issue ? "issues" : "pull"
        return ToolkitGitHubWriteResult(number: created.number, url: try githubPage(repository, "\(collectionPath)/\(created.number)"))
    }

    private struct Payload: Encodable {
        let title: String
        let body: String
        let head: String?
        let base: String?
    }

    private struct Receipt: Decodable {
        let number: Int
    }
}
