import AidesCore
import Foundation
import Vapor

func configureRoutes(_ app: Application, service: AidesService) {
    let api = app.grouped("api", "v1")
    api.get("health") { _ in try json(HealthResult()) }
    api.post("pair") { request in
        let input = try decode(PairingRequest.self, request)
        return try await json(service.pair(code: input.code, name: input.name))
    }

    api.get("state") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.state(deviceID: device))
    }
    api.get("events") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.state(after: request.query[Int.self, at: "after"], deviceID: device))
    }
    api.post("pair", "invites") { request in
        _ = try await service.authenticatedDevice(request)
        return try json(InviteResult(code: service.host.createInvite()))
    }
    api.delete("devices", ":id") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.revoke(id(request)))
    }
    api.post("threads") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.createThread(decode(NewThread.self, request)))
    }
    api.post("threads", ":id", "messages") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.message(in: id(request), text: decode(NewMessage.self, request).text))
    }
    api.post("threads", ":id", "archive") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.archive(id: id(request), report: decode(ArchiveThread.self, request).report))
    }
    api.post("projects") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.createProject(decode(NewProject.self, request)))
    }
    api.post("settings") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.updateSettings(decode(SettingsChange.self, request)))
    }
    api.post("models") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.addModel(decode(NewModel.self, request)))
    }
    api.get("memory") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.memories())
    }
    api.post("memory") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.saveMemory(decode(NewMemory.self, request)))
    }
    api.delete("memory", ":id") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.deleteMemory(id(request)))
    }
    api.post("tasks") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.createTask(decode(NewTask.self, request)))
    }
    api.post("tasks", ":id", "approve") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.approveTask(id(request), approved: decode(TaskApproval.self, request).approved))
    }
    api.post("tasks", ":id", "cancel") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.cancelTask(id(request)))
    }
    api.post("tasks", ":id", "resume") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.resumeTask(id(request)))
    }
    api.post("schedules") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.createSchedule(decode(NewSchedule.self, request)))
    }
    api.post("schedules", ":id", "pause") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.pauseSchedule(id(request), paused: decode(SchedulePause.self, request).paused))
    }
    api.post("reviews") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.createReview(decode(NewReview.self, request)))
    }
    api.post("reviews", ":id", "clarify") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.clarifyReview(id(request), text: decode(ClarifyReview.self, request).clarification))
    }
}

private func id(_ request: Request) throws -> UUID {
    guard let value = request.parameters.get("id"), let id = UUID(uuidString: value) else {
        throw Abort(.badRequest, reason: "Invalid identifier.")
    }
    return id
}

private func decode<Value: Decodable>(_ type: Value.Type, _ request: Request) throws -> Value {
    guard let body = request.body.data else { throw Abort(.badRequest, reason: "Missing request body.") }
    do {
        return try AppJSON.decoder().decode(type, from: Data(body.readableBytesView))
    } catch {
        throw Abort(.badRequest, reason: "The request does not match the expected data format.")
    }
}

private func json(_ value: some Encodable) throws -> Response {
    var headers = HTTPHeaders()
    headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
    headers.replaceOrAdd(name: .cacheControl, value: "no-store")
    return Response(status: .ok, headers: headers, body: .init(data: try AppJSON.encoder().encode(value)))
}
