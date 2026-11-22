import Foundation

public enum ToolkitCategory: String, Codable, Sendable {
    case files
}

public enum ToolkitApproval: String, Codable, Sendable {
    case grantedResource, targetDevice
}

public enum ToolkitTool: String, Codable, CaseIterable, Sendable {
    case listDirectory = "files.list"
    case readTextFile = "files.read"
    case moveFile = "files.move"

    public var descriptor: ToolkitToolDescriptor {
        switch self {
        case .listDirectory:
            ToolkitToolDescriptor(id: self, category: .files, title: "List directory", approval: .grantedResource)
        case .readTextFile:
            ToolkitToolDescriptor(id: self, category: .files, title: "Read text file", approval: .grantedResource)
        case .moveFile:
            ToolkitToolDescriptor(id: self, category: .files, title: "Move file", approval: .targetDevice)
        }
    }
}

public struct ToolkitToolDescriptor: Codable, Identifiable, Sendable {
    public let id: ToolkitTool
    public let category: ToolkitCategory
    public let title: String
    public let approval: ToolkitApproval
}

public struct ToolkitFolderResource: Codable, Identifiable, Sendable {
    public let id: UUID
    public let deviceID: UUID
    public let name: String
    public let tools: [ToolkitTool]

    public init(id: UUID, deviceID: UUID, name: String, tools: [ToolkitTool]) {
        self.id = id
        self.deviceID = deviceID
        self.name = name
        self.tools = tools
    }
}

public struct ToolkitCatalog: Codable, Sendable {
    public let tools: [ToolkitToolDescriptor]
    public let resources: [ToolkitFolderResource]

    public init(tools: [ToolkitToolDescriptor], resources: [ToolkitFolderResource]) {
        self.tools = tools
        self.resources = resources
    }
}

public struct ToolkitInvocationRequest: Codable, Sendable {
    public let id: UUID
    public let tool: ToolkitTool
    public let resourceID: UUID
    public let path: String
    public let destination: String?

    public init(id: UUID = UUID(), tool: ToolkitTool, resourceID: UUID, path: String, destination: String? = nil) {
        self.id = id
        self.tool = tool
        self.resourceID = resourceID
        self.path = path
        self.destination = destination
    }
}

public enum ToolkitInvocationStatus: String, Codable, Sendable {
    case queued, running, completed, failed, cancelled, interrupted

    public var isActive: Bool { self == .queued || self == .running }
}

public struct ToolkitInvocation: Codable, Identifiable, Sendable {
    public let id: UUID
    public let tool: ToolkitTool
    public let resourceID: UUID
    public let deviceID: UUID
    public let requestedByDeviceID: UUID?
    public let path: String
    public let destination: String?
    public let status: ToolkitInvocationStatus
    public let result: String?
    public let error: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID, tool: ToolkitTool, resourceID: UUID, deviceID: UUID, requestedByDeviceID: UUID?,
        path: String, destination: String?, status: ToolkitInvocationStatus, result: String?, error: String?,
        createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.tool = tool
        self.resourceID = resourceID
        self.deviceID = deviceID
        self.requestedByDeviceID = requestedByDeviceID
        self.path = path
        self.destination = destination
        self.status = status
        self.result = result
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
