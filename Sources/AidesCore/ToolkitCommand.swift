import Foundation

public struct ToolkitCommand: Codable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let projectID: UUID
    public let executable: String
    public let arguments: [String]
    public let timeoutSeconds: Int
    public let revision: String

    public init(
        id: String, label: String, projectID: UUID, executable: String,
        arguments: [String], timeoutSeconds: Int, revision: String
    ) {
        self.id = id
        self.label = label
        self.projectID = projectID
        self.executable = executable
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
        self.revision = revision
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
    public var stopRequested: Bool?
    public let revision: String?

    public init(id: UUID, commandID: String, requestedByDeviceID: UUID, revision: String) {
        self.id = id
        self.commandID = commandID
        self.requestedByDeviceID = requestedByDeviceID
        self.revision = revision
        createdAt = .now
        status = .running
    }
}
