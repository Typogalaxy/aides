import AidesCore
import AidesExecution
import Foundation
import Vapor

private struct GitHubRepositoryConfiguration: Decodable, Sendable {
    let id: String
    let owner: String
    let name: String
    let label: String?
    let publicRead: Bool?

    var isValid: Bool {
        let slug = "abcdefghijklmnopqrstuvwxyz0123456789_-"
        let repositoryName = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"
        return (1...64).contains(id.utf8.count) && id.utf8.allSatisfy(slug.utf8.contains) &&
            (1...39).contains(owner.utf8.count) && owner.utf8.allSatisfy { byte in
                byte != 95 && byte != 46 && repositoryName.utf8.contains(byte)
            } &&
            (1...100).contains(name.utf8.count) && name != "." && name != ".." &&
            name.utf8.allSatisfy(repositoryName.utf8.contains) &&
            (label.map { (1...100).contains($0.utf8.count) &&
                !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) } ?? true)
    }

    func repository(available: Bool) -> ToolkitGitHubRepository {
        ToolkitGitHubRepository(id: id, owner: owner, name: name, label: label ?? "\(owner)/\(name)", available: available)
    }

    func token(in storage: ToolkitHostConfiguration) throws -> String? {
        guard let candidate = try storage.read("github-\(id).token") else { return nil }
        let token = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...1024).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw Abort(.serviceUnavailable, reason: "Check the repository token on the host.")
        }
        return token
    }
}

extension AidesService {
    func toolkitGitHubRepositories(deviceID: UUID) async throws -> [ToolkitGitHubRepository] {
        try Self.requireGitHubDevice(deviceID, in: await store.snapshot())
        let storage = githubStorage
        return try gitHubRepositories().map { config in
            do {
                let token = try config.token(in: storage)
                return config.repository(available: token != nil || config.publicRead == true)
            } catch {
                return config.repository(available: false)
            }
        }
    }

    func toolkitGitHubItems(
        repositoryID: String, request: ToolkitGitHubItemsRequest, deviceID: UUID
    ) async throws -> [ToolkitGitHubItem] {
        try Self.requireGitHubDevice(deviceID, in: await store.snapshot())
        let limit = request.limit ?? 10
        guard (1...20).contains(limit) else {
            throw Abort(.badRequest, reason: "Use a GitHub result limit from 1 through 20.")
        }
        guard let config = try gitHubRepositories().first(where: { $0.id == repositoryID }) else {
            throw Abort(.notFound, reason: "GitHub repository is not configured.")
        }
        let token = try config.token(in: githubStorage)
        guard token != nil || config.publicRead == true else {
            throw Abort(.serviceUnavailable, reason: "Configure the protected GitHub repository token on the host.")
        }
        do {
            return try await ToolkitGitHubConnector().items(
                repository: config.repository(available: true), token: token, kind: request.kind, limit: limit
            )
        } catch ToolkitRemoteError.unauthorized {
            throw Abort(.forbidden, reason: "GitHub did not authorize this repository read.")
        } catch {
            throw Abort(.badGateway, reason: "GitHub could not return the requested repository items.")
        }
    }

    private var githubStorage: ToolkitHostConfiguration {
        ToolkitHostConfiguration(directory: host.directory)
    }

    private func gitHubRepositories() throws -> [GitHubRepositoryConfiguration] {
        guard let raw = try githubStorage.read("github-repositories.json") else { return [] }
        guard let repositories = try? JSONDecoder().decode([GitHubRepositoryConfiguration].self, from: Data(raw.utf8)),
              repositories.count <= 24, repositories.allSatisfy(\.isValid),
              Set(repositories.map(\.id)).count == repositories.count else {
            throw Abort(.serviceUnavailable, reason: "Check github-repositories.json on the host.")
        }
        return repositories
    }

    private static func requireGitHubDevice(_ deviceID: UUID, in state: ServerState) throws {
        guard state.app.devices.contains(where: { $0.id == deviceID }) else {
            throw Abort(.unauthorized, reason: "Pair this device to continue.")
        }
    }
}

func registerToolkitGitHubRoutes(_ group: RoutesBuilder, service: AidesService) {
    let github = group.grouped("github", "repositories")
    github.get { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.toolkitGitHubRepositories(deviceID: device))
    }
    github.post(":id", "items") { request in
        let device = try await service.authenticatedDevice(request)
        guard let id = request.parameters.get("id") else { throw Abort(.badRequest) }
        return try await json(service.toolkitGitHubItems(
            repositoryID: id, request: decode(ToolkitGitHubItemsRequest.self, request), deviceID: device
        ))
    }
}
