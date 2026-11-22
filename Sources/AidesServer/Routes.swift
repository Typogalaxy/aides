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
        let device = try await service.authenticatedDevice(request)
        return try await json(service.message(in: id(request), input: decode(NewMessage.self, request), deviceID: device))
    }
    api.post("threads", ":id", "archive") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.archive(id: id(request), report: decode(ArchiveThread.self, request).report))
    }
    api.post("projects") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.createProject(decode(NewProject.self, request)))
    }
    api.post("projects", ":id", "watch") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.watchProject(id(request), enabled: decode(ProjectWatch.self, request).enabled))
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
        let device = try await service.authenticatedDevice(request)
        return try await json(service.createTask(decode(NewTask.self, request), deviceID: device))
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
    api.post("code-proposals") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.createProposal(decode(NewCodeProposal.self, request)))
    }
    api.get("code-proposals", ":id") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.proposalDetails(id(request)))
    }
    api.post("code-proposals", ":id", "apply") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.applyProposal(id(request), path: decode(ApplyCodeChange.self, request).path))
    }
    api.post("schedules", "suggestions", ":id", "accept") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.acceptScheduleSuggestion(messageID: id(request)))
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
    api.post("reviews", ":id", "finish") { request in
        _ = try await service.authenticatedDevice(request)
        return try await json(service.closeReview(id(request)))
    }
    let toolkit = api.grouped("toolkit")
    registerToolkitLocalRoutes(toolkit, service: service)
    registerToolkitCommandRoutes(toolkit, service: service)
    toolkit.post("suggestions", ":id", "accept") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.acceptToolkitSuggestion(id(request), deviceID: device))
    }
    toolkit.get("catalog") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.toolkitCatalog(deviceID: device))
    }
    toolkit.post("invocations") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.invokeToolkit(decode(ToolkitInvocationRequest.self, request), deviceID: device))
    }
    toolkit.get("invocations", ":id") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.toolkitInvocation(id(request), deviceID: device))
    }
    api.get("device-files") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.deviceFileManifest(deviceID: device))
    }
    api.post("device-files", "grants") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.grantDeviceFile(decode(NewDeviceFileGrant.self, request), deviceID: device))
    }
    api.delete("device-files", "grants", ":id") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.revokeDeviceFileGrant(id(request), deviceID: device))
    }
    api.post("device-files", "jobs") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.createDeviceFileJob(decode(NewDeviceFileJob.self, request), deviceID: device))
    }
    api.post("device-files", "jobs", "next") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.claimDeviceFileJob(deviceID: device))
    }
    api.post("device-files", "jobs", ":id", "finish") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.finishDeviceFileJob(id(request), input: decode(FinishDeviceFileJob.self, request), deviceID: device))
    }
}

private func id(_ request: Request) throws -> UUID {
    guard let value = request.parameters.get("id"), let id = UUID(uuidString: value) else {
        throw Abort(.badRequest, reason: "Invalid identifier.")
    }
    return id
}

func decode<Value: Decodable>(_ type: Value.Type, _ request: Request) throws -> Value {
    guard let body = request.body.data else { throw Abort(.badRequest, reason: "Missing request body.") }
    do {
        return try AppJSON.decoder().decode(type, from: Data(body.readableBytesView))
    } catch {
        throw Abort(.badRequest, reason: "The request does not match the expected data format.")
    }
}

func json(_ value: some Encodable) throws -> Response {
    var headers = HTTPHeaders()
    headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
    headers.replaceOrAdd(name: .cacheControl, value: "no-store")
    return Response(status: .ok, headers: headers, body: .init(data: try AppJSON.encoder().encode(value)))
}
