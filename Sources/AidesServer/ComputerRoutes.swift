import AidesCore
import Foundation
import Vapor

func registerComputerRoutes(_ toolkit: RoutesBuilder, service: AidesService) {
    let computer = toolkit.grouped("computer")
    computer.get("runs") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.computer.list(deviceID: device))
    }
    computer.post("runs") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.computer.create(decode(NewComputerRun.self, request), from: device))
    }
    computer.post("runs", ":id", "permission") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.computer.permit(
            computerID(request), input: decode(ComputerPermission.self, request), deviceID: device
        ))
    }
    computer.post("runs", ":id", "decision") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.computer.decide(
            computerID(request), input: decode(ComputerDecision.self, request), deviceID: device
        ))
    }
    for operation in ["pause", "resume", "stop"] {
        computer.post("runs", ":id", .constant(operation)) { request in
            let device = try await service.authenticatedDevice(request)
            return try await json(service.computer.control(computerID(request), verb: operation, deviceID: device))
        }
    }
    computer.post("next") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.computer.next(for: device))
    }
    computer.get("runs", ":id", "commands", ":command") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.computer.checkClaim(
            computerID(request), commandID: computerID(request, parameter: "command"), deviceID: device
        ))
    }
    computer.on(.POST, "runs", ":id", "receipt", body: .collect(maxSize: "768kb")) { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.computer.receipt(
            computerID(request), input: decode(ComputerReceipt.self, request), deviceID: device
        ))
    }
}

private func computerID(_ request: Request, parameter: String = "id") throws -> UUID {
    guard let value = request.parameters.get(parameter), let id = UUID(uuidString: value) else { throw Abort(.badRequest) }
    return id
}
