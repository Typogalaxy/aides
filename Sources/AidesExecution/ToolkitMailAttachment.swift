import AidesCore
import CryptoKit
import Foundation

public enum ToolkitMailAttachmentPreviewError: Error, Equatable, Sendable {
    case changed, unsupported
}

struct MailAttachmentReference {
    static let maximumBytes = 16 * 1_024
    let id: String?
    let metadata: ToolkitMailAttachment

    init(
        id: String?, scope: String, name: String, type: String?, size: Int?, inline: Bool
    ) {
        self.id = id
        let key: String?
        if let id, let size, (0...Self.maximumBytes).contains(size), let type, Self.supportedType(type) != nil,
           let context = try? JSONEncoder().encode([scope, id, name, type, String(size), String(inline)]) {
            key = SHA256.hash(data: context).map { String(format: "%02x", $0) }.joined()
        } else {
            key = nil
        }
        metadata = ToolkitMailAttachment(
            name: ToolkitRemoteTransport.bounded(name, limit: 512),
            contentType: type.map { ToolkitRemoteTransport.bounded($0, limit: 120) },
            byteCount: size.flatMap { $0 >= 0 ? $0 : nil },
            isInline: inline,
            previewKey: key
        )
    }

    static func select(
        _ selection: ToolkitMailAttachmentPreviewRequest, from references: [MailAttachmentReference]
    ) throws -> MailAttachmentReference {
        guard references.indices.contains(selection.index) else { throw ToolkitMailAttachmentPreviewError.changed }
        let reference = references[selection.index]
        guard let key = reference.metadata.previewKey else { throw ToolkitMailAttachmentPreviewError.unsupported }
        guard key == selection.previewKey else { throw ToolkitMailAttachmentPreviewError.changed }
        return reference
    }

    func preview(_ bytes: Data) throws -> ToolkitMailAttachmentPreview {
        guard bytes.count <= Self.maximumBytes, bytes.count == metadata.byteCount,
              let contentType = metadata.contentType.flatMap(Self.supportedType),
              let text = String(data: bytes, encoding: .utf8),
              !text.unicodeScalars.contains(where: { scalar in
                  (CharacterSet.controlCharacters.contains(scalar) && ![9, 10, 13].contains(scalar.value)) ||
                  (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
              }) else {
            throw ToolkitMailAttachmentPreviewError.unsupported
        }
        return ToolkitMailAttachmentPreview(name: metadata.name, contentType: contentType, text: text)
    }

    private static func supportedType(_ value: String) -> String? {
        guard value.utf8.count <= 120 else { return nil }
        let fields = value.lowercased().split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let mediaType = fields.first, ["text/plain", "text/csv", "text/tab-separated-values", "text/markdown"].contains(mediaType),
              fields.dropFirst().allSatisfy({ ["charset=utf-8", "charset=\"utf-8\"", "charset=us-ascii"].contains($0) }) else {
            return nil
        }
        return mediaType
    }
}
