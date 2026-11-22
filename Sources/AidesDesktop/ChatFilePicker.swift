import AidesCore
import AppKit
import Foundation

@MainActor
enum ChatFilePicker {
    static func select(keeping existing: [ChatFileAttachment]) async throws -> [ChatFileAttachment]? {
        guard existing.count < ChatFileAttachment.maximumCount else { throw ChatAttachmentError.count }

        let panel = NSOpenPanel()
        panel.title = "Attach files and folders"
        panel.prompt = "Attach"
        panel.message = "Select UTF-8 text files or folders. A folder shares only its immediate file and folder names."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false

        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK else { return nil }
        let urls = panel.urls
        guard existing.count + urls.count <= ChatFileAttachment.maximumCount else { throw ChatAttachmentError.count }
        let snapshots = try await Task.detached(priority: .userInitiated) {
            try urls.map(ChatFileSnapshot.read)
        }.value
        let result = existing + snapshots
        try ChatFileAttachment.validate(result)
        return result
    }
}
