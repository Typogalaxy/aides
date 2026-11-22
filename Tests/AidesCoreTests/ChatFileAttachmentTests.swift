import AidesCore
import Foundation
import Testing

struct ChatFileAttachmentTests {
    @Test func snapshotsOnlySelectedTextAndImmediateFolderNames() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "aides-chat-attachments-\(UUID().uuidString)", directoryHint: .isDirectory)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }

        let note = folder.appending(path: "notes.md")
        try "A private note".write(to: note, atomically: true, encoding: .utf8)
        try "secret".write(to: folder.appending(path: ".env"), atomically: true, encoding: .utf8)
        let subfolder = folder.appending(path: "nested", directoryHint: .isDirectory)
        try files.createDirectory(at: subfolder, withIntermediateDirectories: false)
        try "not enumerated".write(to: subfolder.appending(path: "inside.txt"), atomically: true, encoding: .utf8)
        let link = folder.appending(path: "linked.txt")
        try files.createSymbolicLink(at: link, withDestinationURL: note)

        let file = try ChatFileSnapshot.read(note)
        #expect(file.kind == .file)
        #expect(file.name == "notes.md")
        #expect(file.text == "A private note")

        let listing = try ChatFileSnapshot.read(folder)
        #expect(listing.kind == .folder)
        #expect(listing.name == folder.lastPathComponent)
        #expect(listing.entries == ["nested/", "notes.md"])
        #expect(listing.text == nil)
        #expect(listing.truncated == false)

        #expect(throws: ChatAttachmentError.self) { try ChatFileSnapshot.read(link) }
        #expect(throws: ChatAttachmentError.self) { try ChatFileSnapshot.read(folder.appending(path: ".env")) }
        let escapingParent = folder.appending(path: "escape")
        try files.createSymbolicLink(at: escapingParent, withDestinationURL: subfolder)
        #expect(throws: (any Error).self) {
            try ChatFileSnapshot.read(escapingParent.appending(path: "inside.txt"))
        }
    }

    @Test func enforcesPayloadBoundsAndKeepsContentsOutOfMessageLabels() throws {
        let text = ChatFileAttachment(name: "notes.txt", text: "private contents")
        let label = text.label
        let message = Message("Read this", role: .user, attachments: [label])
        let encoded = try AppJSON.encoder().encode(message)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("private contents"))
        let restored = try AppJSON.decoder().decode(Message.self, from: encoded)
        #expect(restored.attachments == [label])
        try ChatFileAttachment.validate([text])

        let oldMessage = Data("""
            {"id":"\(UUID())","text":"Before attachments","role":"user","createdAt":"2026-11-22T00:00:00Z"}
            """.utf8)
        #expect(try AppJSON.decoder().decode(Message.self, from: oldMessage).attachments == nil)

        #expect(throws: ChatAttachmentError.self) { try ChatFileAttachment.validate([text, text]) }
        #expect(throws: ChatAttachmentError.self) {
            try ChatFileAttachment.validate([.init(name: "unsafe", entries: ["../secrets"], truncated: false)])
        }
        #expect(throws: ChatAttachmentError.self) {
            try ChatFileAttachment.validate([.init(name: "binary.txt", text: "nul\0byte")])
        }
        #expect(throws: ChatAttachmentError.self) {
            let limit = ChatFileAttachment.maximumFileBytes
            try ChatFileAttachment.validate([.init(name: "large.txt", text: String(repeating: "x", count: limit + 1))])
        }
        #expect(throws: ChatAttachmentError.self) {
            let limit = ChatFileAttachment.maximumFileBytes
            let first = ChatFileAttachment(name: "first.txt", text: String(repeating: "x", count: limit))
            let second = ChatFileAttachment(name: "second.txt", text: String(repeating: "y", count: limit))
            try ChatFileAttachment.validate([first, second])
        }
    }
}
