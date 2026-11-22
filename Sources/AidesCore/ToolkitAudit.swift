import Foundation

public struct ToolkitAuditEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let deviceID: UUID
    public let action: String
    public let status: UInt
    public let date: Date

    public init(deviceID: UUID, action: String, status: UInt) {
        id = UUID()
        self.deviceID = deviceID
        self.action = action
        self.status = status
        date = .now
    }
}
