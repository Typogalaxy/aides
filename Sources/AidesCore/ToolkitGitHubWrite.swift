import Foundation

public enum ToolkitGitHubWriteKind: String, Codable, CaseIterable, Sendable {
    case issue, pullRequest

    public var title: String {
        switch self {
        case .issue: "Issue"
        case .pullRequest: "Pull request"
        }
    }
}

public struct ToolkitGitHubWriteRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let repositoryID: String
    public let kind: ToolkitGitHubWriteKind
    public let title: String
    public let body: String
    public let head: String?
    public let base: String?

    public init(
        id: UUID = UUID(), repositoryID: String, kind: ToolkitGitHubWriteKind, title: String, body: String,
        head: String? = nil, base: String? = nil
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.kind = kind
        self.title = title
        self.body = body
        self.head = head
        self.base = base
    }

    public var isValid: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 240, !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              body.utf8.count <= 16_384, !body.utf8.contains(0) else { return false }
        switch kind {
        case .issue:
            return head == nil && base == nil
        case .pullRequest:
            guard let head, let base, head != base else { return false }
            return Self.isBranch(head) && Self.isBranch(base)
        }
    }

    private static func isBranch(_ name: String) -> Bool {
        let allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/"
        guard (1...240).contains(name.utf8.count), name.utf8.allSatisfy(allowed.utf8.contains),
              !name.hasPrefix("-"), !name.hasPrefix("refs/"), !name.hasSuffix("."), !name.contains("..") else {
            return false
        }
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && !part.hasPrefix(".") && !part.hasSuffix(".lock")
        }
    }
}

public enum ToolkitGitHubWriteStatus: String, Codable, Sendable {
    case awaitingConfirmation, submitting, submitted, declined, interrupted

    public var isActive: Bool { self == .awaitingConfirmation || self == .submitting }
}

public struct ToolkitGitHubWrite: Codable, Identifiable, Sendable {
    public let request: ToolkitGitHubWriteRequest
    public let repositoryOwner: String
    public let repositoryName: String
    public let requestedByDeviceID: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var status: ToolkitGitHubWriteStatus
    public var number: Int?
    public var url: URL?
    public var error: String?

    public var id: UUID { request.id }

    public init(request: ToolkitGitHubWriteRequest, repository: ToolkitGitHubRepository, deviceID: UUID, now: Date) {
        self.request = request
        repositoryOwner = repository.owner
        repositoryName = repository.name
        requestedByDeviceID = deviceID
        createdAt = now
        updatedAt = now
        status = .awaitingConfirmation
    }
}
