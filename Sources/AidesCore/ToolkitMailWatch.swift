import Foundation

public struct ToolkitMailWatchRequest: Codable, Sendable {
    public let accountID: String
    public let query: String
    public let intervalMinutes: Int
    public let paused: Bool?

    public init(accountID: String, query: String, intervalMinutes: Int, paused: Bool? = nil) {
        self.accountID = accountID
        self.query = query
        self.intervalMinutes = intervalMinutes
        self.paused = paused
    }
}

public struct ToolkitMailWatchStatus: Codable, Identifiable, Sendable {
    public let id: UUID
    public let accountID: String
    public let accountLabel: String
    public let query: String
    public let intervalMinutes: Int
    public let paused: Bool
    public let nextCheckAt: Date
    public let lastCheckedAt: Date?
    public let lastError: String?
    public let matchingCount: Int

    public init(
        id: UUID, accountID: String, accountLabel: String, query: String, intervalMinutes: Int,
        paused: Bool, nextCheckAt: Date, lastCheckedAt: Date?, lastError: String?, matchingCount: Int
    ) {
        self.id = id
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.query = query
        self.intervalMinutes = intervalMinutes
        self.paused = paused
        self.nextCheckAt = nextCheckAt
        self.lastCheckedAt = lastCheckedAt
        self.lastError = lastError
        self.matchingCount = matchingCount
    }
}

public struct ToolkitMailWatchList: Codable, Sendable {
    public let watches: [ToolkitMailWatchStatus]

    public init(watches: [ToolkitMailWatchStatus]) { self.watches = watches }
}
