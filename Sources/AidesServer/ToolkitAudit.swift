import AidesCore
import Foundation
import Vapor

struct ToolkitAuditMiddleware: AsyncMiddleware {
    let service: AidesService

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let action = Self.action(for: request),
              let deviceID = try? await service.authenticatedDevice(request) else {
            return try await next.respond(to: request)
        }
        do {
            let response = try await next.respond(to: request)
            await append(deviceID: deviceID, action: action, status: response.status.code)
            return response
        } catch {
            let status = (error as? any AbortError)?.status.code ?? 500
            await append(deviceID: deviceID, action: action, status: status)
            throw error
        }
    }

    private static func action(for request: Request) -> String? {
        guard let route = request.route else { return nil }
        let components = route.path.dropFirst(3).map(\.description)
        let isMailRead = components.first == "mail" && components.contains("messages")
        guard !components.isEmpty,
              request.method == .POST || request.method == .DELETE || (request.method == .GET && isMailRead) else {
            return nil
        }
        // Use only the static route template. Never store message IDs, arguments, query terms, or outputs.
        return request.method.rawValue + " " + components.joined(separator: "/")
    }

    private func append(deviceID: UUID, action: String, status: UInt) async {
        do {
            try await service.store.update { state in
                var history = state.toolkitAudit ?? []
                history.append(ToolkitAuditEntry(deviceID: deviceID, action: action, status: status))
                state.toolkitAudit = Array(history.suffix(128))
            }
        } catch {
            FileHandle.standardError.write(Data("Toolkit audit could not record an action.\n".utf8))
        }
    }
}

func registerToolkitAuditRoutes(_ group: RoutesBuilder, service: AidesService) {
    group.get("audit") { request in
        let id = try await service.authenticatedDevice(request)
        let state = await service.store.snapshot()
        guard state.app.devices.contains(where: { $0.id == id }) else { throw Abort(.unauthorized) }
        return try json(Array((state.toolkitAudit ?? []).reversed()))
    }
}
