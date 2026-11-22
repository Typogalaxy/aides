import Darwin
import Foundation
import Vapor

@main
struct Entry {
    static func main() async throws {
        umask(0o077)
        let host = try Host()
        let command = CommandLine.arguments.dropFirst().first ?? "serve"
        if command == "invite" {
            print(try host.createInvite())
            return
        }
        guard command == "serve" else {
            print("Usage: AidesServer serve | invite")
            return
        }
        let descriptor = try host.acquireProcessLock()
        defer { close(descriptor) }

        var environment = try Environment.detect(arguments: [CommandLine.arguments[0], "serve"])
        try LoggingSystem.bootstrap(from: &environment)
        let app = try await Application.make(environment)
        do {
            app.http.server.configuration.hostname = host.bind
            app.http.server.configuration.port = host.port
            app.routes.defaultMaxBodySize = "128kb"
            let service = try await AidesService(host: host)
            configureRoutes(app, service: service)
            let scheduler = Task { await service.start() }
            defer { scheduler.cancel() }
            do {
                try await app.execute()
            } catch {
                await service.commands.shutdown()
                throw error
            }
            await service.commands.shutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
