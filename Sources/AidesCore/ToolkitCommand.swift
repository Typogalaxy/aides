import Foundation

public struct ToolkitCommand: Codable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let projectID: UUID

    public init(id: String, label: String, projectID: UUID) {
        self.id = id
        self.label = label
        self.projectID = projectID
    }
}

public struct ToolkitCommandRun: Codable, Identifiable, Sendable {
    public let id: UUID
    public let commandID: String
    public let requestedByDeviceID: UUID
    public let createdAt: Date
    public var status: ToolkitInvocationStatus
    public var output: String?
    public var message: String?
    public var exitCode: Int32?

    public init(id: UUID, commandID: String, requestedByDeviceID: UUID) {
        self.id = id
        self.commandID = commandID
        self.requestedByDeviceID = requestedByDeviceID
        createdAt = .now
        status = .running
    }
}
