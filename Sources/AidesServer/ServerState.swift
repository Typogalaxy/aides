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
    var toolkitGitHubWrites: [UUID: ToolkitGitHubWrite]?
    var toolkitGitHubRetiredWriteIDs: Set<UUID>?
    var toolkitFeeds: [ToolkitFeed]?
    var toolkitCommandRuns: [UUID: ToolkitCommandRun]?
    var toolkitMailWatches: [ToolkitMailWatch]?
    var toolkitMailArchives: [UUID: ToolkitMailArchive]?
    var toolkitMailRetiredArchiveIDs: Set<UUID>?
    var toolkitMailDrafts: [UUID: ToolkitMailDraft]?
    var toolkitMailRetiredDraftIDs: Set<UUID>?
    var acceptedScheduleSuggestions: [UUID: UUID]?

    mutating func revise() {
        app.revision += 1
    }
}
