import Foundation

public struct ToolkitMailArchiveRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let accountID: String
    public let messageID: String

    public init(id: UUID = UUID(), accountID: String, messageID: String) {
        self.id = id
        self.accountID = accountID
        self.messageID = messageID
    }
}

public enum ToolkitMailArchiveStatus: String, Codable, Sendable {
    case awaitingConfirmation, archiving, archived, declined, interrupted

    public var isActive: Bool { self == .awaitingConfirmation || self == .archiving }
}

public struct ToolkitMailArchive: Codable, Identifiable, Sendable {
    public let id: UUID
    public let accountID: String
    public let accountProvider: ToolkitMailProvider
    public let accountLabel: String
    public let accountAddress: String
    public let messageID: String
    public let subject: String
    public let from: String
    public let requestedByDeviceID: UUID
    public var status: ToolkitMailArchiveStatus
    public var error: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        request: ToolkitMailArchiveRequest, account: ToolkitMailAccount, message: ToolkitMailMessage,
        requestedByDeviceID: UUID, now: Date
    ) {
        id = request.id
        accountID = account.id
        accountProvider = account.provider
        accountLabel = account.label
        accountAddress = account.address
        messageID = request.messageID
        subject = message.subject
        from = message.from
        self.requestedByDeviceID = requestedByDeviceID
        status = .awaitingConfirmation
        error = nil
        createdAt = now
        updatedAt = now
    }

    public var request: ToolkitMailArchiveRequest {
        ToolkitMailArchiveRequest(id: id, accountID: accountID, messageID: messageID)
    }
}
