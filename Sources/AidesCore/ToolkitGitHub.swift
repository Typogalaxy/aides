import Foundation

public struct ToolkitGitHubRepository: Codable, Identifiable, Sendable {
    public let id: String
    public let owner: String
    public let name: String
    public let label: String
    public let available: Bool
    public let allowedWrites: [ToolkitGitHubWriteKind]?

    public init(
        id: String, owner: String, name: String, label: String, available: Bool,
        allowedWrites: [ToolkitGitHubWriteKind]? = nil
    ) {
        self.id = id
        self.owner = owner
        self.name = name
        self.label = label
        self.available = available
        self.allowedWrites = allowedWrites
    }
}

public enum ToolkitGitHubItemKind: String, Codable, CaseIterable, Sendable {
    case issues, pullRequests, workflowRuns

    public var title: String {
        switch self {
        case .issues: "Issues"
        case .pullRequests: "Pull requests"
        case .workflowRuns: "Workflow runs"
        }
    }
}

public struct ToolkitGitHubItemsRequest: Codable, Sendable {
    public let kind: ToolkitGitHubItemKind
    public let limit: Int?

    public init(kind: ToolkitGitHubItemKind, limit: Int? = nil) {
        self.kind = kind
        self.limit = limit
    }
}

public struct ToolkitGitHubItem: Codable, Identifiable, Sendable {
    public let id: String
    public let number: Int?
    public let title: String
    public let summary: String?
    public let state: String
    public let url: URL
    public let updatedAt: Date?

    public init(id: String, number: Int?, title: String, summary: String?, state: String, url: URL, updatedAt: Date?) {
        self.id = id
        self.number = number
        self.title = title
        self.summary = summary
        self.state = state
        self.url = url
        self.updatedAt = updatedAt
    }
}
