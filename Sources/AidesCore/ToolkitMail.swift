import Foundation

public enum ToolkitMailProvider: String, Codable, CaseIterable, Sendable {
    case gmail, outlook, fastmail

    public var title: String {
        switch self {
        case .gmail: "Gmail"
        case .outlook: "Outlook"
        case .fastmail: "Fastmail"
        }
    }
}

public struct ToolkitMailAccount: Codable, Identifiable, Sendable {
    public let id: String
    public let provider: ToolkitMailProvider
    public let label: String
    public let address: String
    public let available: Bool
    public let allowSend: Bool
    public let allowArchive: Bool

    private enum CodingKeys: String, CodingKey { case id, provider, label, address, available, allowSend, allowArchive }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            provider: try values.decode(ToolkitMailProvider.self, forKey: .provider),
            label: try values.decode(String.self, forKey: .label),
            address: try values.decode(String.self, forKey: .address),
            available: try values.decode(Bool.self, forKey: .available),
            allowSend: try values.decode(Bool.self, forKey: .allowSend),
            allowArchive: try values.decodeIfPresent(Bool.self, forKey: .allowArchive) ?? false
        )
    }

    public init(
        id: String, provider: ToolkitMailProvider, label: String, address: String, available: Bool,
        allowSend: Bool, allowArchive: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.address = address
        self.available = available
        self.allowSend = allowSend
        self.allowArchive = allowArchive
    }
}

public struct ToolkitMailSearchRequest: Codable, Sendable {
    public let query: String
    public let limit: Int?

    public init(query: String, limit: Int? = nil) {
        self.query = query
        self.limit = limit
    }
}

public struct ToolkitMailAttachment: Codable, Sendable {
    public let name: String
    public let contentType: String?
    public let byteCount: Int?
    public let isInline: Bool

    public init(name: String, contentType: String?, byteCount: Int?, isInline: Bool) {
        self.name = name
        self.contentType = contentType
        self.byteCount = byteCount
        self.isInline = isInline
    }
}

public struct ToolkitMailMessage: Codable, Identifiable, Sendable {
    public let id: String
    public let subject: String
    public let from: String
    public let preview: String
    public let body: String?
    public let receivedAt: Date?
    public let attachments: [ToolkitMailAttachment]

    public init(
        id: String, subject: String, from: String, preview: String, body: String? = nil,
        receivedAt: Date? = nil, attachments: [ToolkitMailAttachment] = []
    ) {
        self.id = id
        self.subject = subject
        self.from = from
        self.preview = preview
        self.body = body
        self.receivedAt = receivedAt
        self.attachments = attachments
    }
}

public struct ToolkitMailDraftRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let accountID: String
    public let to: [String]
    public let subject: String
    public let body: String

    public init(id: UUID = UUID(), accountID: String, to: [String], subject: String, body: String) {
        self.id = id
        self.accountID = accountID
        self.to = to
        self.subject = subject
        self.body = body
    }
}

public enum ToolkitMailDraftStatus: String, Codable, Sendable {
    case awaitingConfirmation, sending, submitted, declined, interrupted
}

public struct ToolkitMailDraft: Codable, Identifiable, Sendable {
    public let id: UUID
    public let accountID: String
    public let accountProvider: ToolkitMailProvider
    public let accountLabel: String
    public let accountAddress: String
    public let to: [String]
    public let subject: String
    public let body: String
    public let requestedByDeviceID: UUID
    public var status: ToolkitMailDraftStatus
    public var error: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(request: ToolkitMailDraftRequest, account: ToolkitMailAccount, requestedByDeviceID: UUID, now: Date) {
        id = request.id
        accountID = account.id
        accountProvider = account.provider
        accountLabel = account.label
        accountAddress = account.address
        to = request.to
        subject = request.subject
        body = request.body
        self.requestedByDeviceID = requestedByDeviceID
        status = .awaitingConfirmation
        error = nil
        createdAt = now
        updatedAt = now
    }

    public var request: ToolkitMailDraftRequest {
        ToolkitMailDraftRequest(id: id, accountID: accountID, to: to, subject: subject, body: body)
    }
}

public struct ToolkitMailDecision: Codable, Sendable {
    public let approved: Bool

    public init(approved: Bool) {
        self.approved = approved
    }
}
