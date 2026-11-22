import AidesCore
import Foundation
import Vapor

extension AidesService {
    func toolkitCatalog(deviceID: UUID) async throws -> ToolkitCatalog {
        let files = try await deviceFileManifest(deviceID: deviceID)
        let resources = files.grants.map { grant in
            ToolkitFolderResource(
                id: grant.id, deviceID: grant.deviceID, name: grant.name,
                tools: grant.allowMoves ? ToolkitTool.allCases : [.listDirectory, .readTextFile]
            )
        }
        return ToolkitCatalog(tools: ToolkitTool.allCases.map(\.descriptor), resources: resources)
    }

    func invokeToolkit(
        _ input: ToolkitInvocationRequest, deviceID: UUID,
        authorize: @Sendable (ServerState) throws -> Void = { _ in }
    ) async throws -> ToolkitInvocation {
        let operation: DeviceFileOperation = switch input.tool {
        case .listDirectory: .list
        case .readTextFile: .read
        case .moveFile: .move
        }
        let job = try await createDeviceFileJob(
            NewDeviceFileJob(grantID: input.resourceID, operation: operation, path: input.path, destination: input.destination),
            deviceID: deviceID, invocationID: input.id, authorize: authorize
        )
        return job.toolkitInvocation
    }

    func toolkitInvocation(_ id: UUID, deviceID: UUID) async throws -> ToolkitInvocation {
        let files = try await deviceFileManifest(deviceID: deviceID)
        if let job = files.jobs.first(where: { $0.id == id && $0.requestedByDeviceID != nil }) {
            return job.toolkitInvocation
        }
        if files.retiredInvocationIDs?.contains(id) == true {
            throw Abort(.gone, reason: "This invocation's history expired.")
        }
        throw Abort(.notFound, reason: "Toolkit invocation not found.")
    }
}

private extension DeviceFileJob {
    var toolkitInvocation: ToolkitInvocation {
        let tool: ToolkitTool = switch operation {
        case .list: .listDirectory
        case .read: .readTextFile
        case .move: .moveFile
        }
        return ToolkitInvocation(
            id: id, tool: tool, resourceID: grantID, deviceID: deviceID,
            requestedByDeviceID: requestedByDeviceID, path: path, destination: destination,
            status: status, result: result, error: error, createdAt: createdAt, updatedAt: updatedAt
        )
    }
}
