import Foundation

public struct ToolkitMailDraftSuggestion: Codable, Sendable {
    public let accountID: String
    public let to: [String]
    public let subject: String
    public let body: String

    public func request(id: UUID) -> ToolkitMailDraftRequest {
        ToolkitMailDraftRequest(id: id, accountID: accountID, to: to, subject: subject, body: body)
    }
}

public struct ToolkitMailGrant: Codable, Sendable {
    public let account: ToolkitMailAccount
    public let requestedByDeviceID: UUID

    public init(account: ToolkitMailAccount, requestedByDeviceID: UUID) {
        self.account = account
        self.requestedByDeviceID = requestedByDeviceID
    }
}
