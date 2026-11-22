import Foundation

public enum ChatAttachmentKind: String, Codable, Equatable, Sendable {
    case file
    case folder
}

public struct ChatAttachmentLabel: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let kind: ChatAttachmentKind
}

public struct ChatFileAttachment: Codable, Identifiable, Sendable {
    public static let maximumCount = 5
    public static let maximumFileBytes = 32 * 1_024
    public static let maximumTotalBytes = 64 * 1_024
    public static let maximumFolderEntries = 80

    public let id: UUID
    public let name: String
    public let kind: ChatAttachmentKind
    public let text: String?
    public let entries: [String]?
    public let truncated: Bool?

    public init(name: String, text: String) {
        id = UUID()
        self.name = name
        kind = .file
        self.text = text
        entries = nil
        truncated = nil
    }

    public init(name: String, entries: [String], truncated: Bool) {
        id = UUID()
        self.name = name
        kind = .folder
        text = nil
        self.entries = entries
        self.truncated = truncated
    }

    public var label: ChatAttachmentLabel {
        ChatAttachmentLabel(id: id, name: name, kind: kind)
    }

    public static func validate(_ attachments: [Self]) throws {
        guard attachments.count <= maximumCount else { throw ChatAttachmentError.count }
        guard Set(attachments.map(\.id)).count == attachments.count else { throw ChatAttachmentError.invalid }
        var total = 0
        for attachment in attachments {
            guard Self.isAllowedName(attachment.name) else { throw ChatAttachmentError.invalid }
            total += attachment.name.utf8.count
            switch attachment.kind {
            case .file:
                guard let text = attachment.text, attachment.entries == nil, attachment.truncated == nil,
                      text.utf8.count <= maximumFileBytes, Self.isPlainText(text) else {
                    throw ChatAttachmentError.text
                }
                total += text.utf8.count
            case .folder:
                guard let entries = attachment.entries, attachment.text == nil, attachment.truncated != nil,
                      entries.count <= maximumFolderEntries, Set(entries).count == entries.count else {
                    throw ChatAttachmentError.invalid
                }
                for entry in entries {
                    let name = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
                    guard Self.isAllowedName(name) else { throw ChatAttachmentError.invalid }
                    total += entry.utf8.count
                }
            }
        }
        guard total <= maximumTotalBytes else { throw ChatAttachmentError.totalSize }
    }

    private static func isAllowedName(_ value: String) -> Bool {
        !value.contains("/") && (try? ProjectFiles.validate(path: value)) != nil
    }

    private static func isPlainText(_ value: String) -> Bool {
        !value.unicodeScalars.contains { scalar in
            (scalar.value < 32 && ![9, 10, 13].contains(scalar.value)) || scalar.value == 127
        }
    }
}

public enum ChatAttachmentError: LocalizedError {
    case count
    case invalid
    case text
    case totalSize

    public var errorDescription: String? {
        switch self {
        case .count: "Attach up to five files or folders per message."
        case .invalid: "Choose a regular file or a specific folder outside protected locations."
        case .text: "Choose a UTF-8 text file no larger than 32 KiB."
        case .totalSize: "Keep the combined attachments under 64 KiB."
        }
    }
}
