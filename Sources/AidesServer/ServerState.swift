import AidesCore
import Foundation

struct PendingChatAttachments: Codable, Sendable {
    static let maximumPendingMessages = 16

    let deviceID: UUID
    let files: [ChatFileAttachment]
}

struct ServerState: Codable, Sendable {
    var app = AppState()
    var tokenOwners: [String: UUID] = [:]
    var memory: [MemoryRecord] = []
    var replyMessages: [UUID: UUID] = [:]
    var pendingChatAttachments: [UUID: PendingChatAttachments]?
    var watchedProjects: [UUID: ProjectFileSnapshot]?
    var proposals: [UUID: PendingCodeProposal]?
    var deviceFiles: DeviceFileState?
    var computerRuns: [UUID: ComputerStoredRun]?
    var toolkitAudit: [ToolkitAuditEntry]?
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

    mutating func discardChatAttachments(for taskID: UUID) {
        pendingChatAttachments?.removeValue(forKey: taskID)
        if pendingChatAttachments?.isEmpty == true { pendingChatAttachments = nil }
    }

    mutating func revokeChatAttachments(from deviceID: UUID) -> [UUID] {
        let affected = Set((pendingChatAttachments ?? [:]).compactMap { taskID, attachments in
            attachments.deviceID == deviceID ? taskID : nil
        })
        for taskID in affected { discardChatAttachments(for: taskID) }
        var running: [UUID] = []
        for index in app.tasks.indices where affected.contains(app.tasks[index].id) && !app.tasks[index].status.isTerminal {
            if app.tasks[index].status == .running { running.append(app.tasks[index].id) }
            app.tasks[index].status = .cancelled
            app.tasks[index].updatedAt = .now
            app.tasks[index].error = "The device that attached these files was revoked."
        }
        return running
    }

    mutating func revise() {
        app.revision += 1
    }
}
