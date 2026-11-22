import AidesCore
import Foundation

struct ServerState: Codable, Sendable {
    var app = AppState()
    var tokenOwners: [String: UUID] = [:]
    var memory: [MemoryRecord] = []
    var replyMessages: [UUID: UUID] = [:]
    var watchedProjects: [UUID: ProjectFileSnapshot]?
    var proposals: [UUID: PendingCodeProposal]?
    var deviceFiles: DeviceFileState?

    mutating func revise() {
        app.revision += 1
    }
}
