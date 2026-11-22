import Foundation

public enum ChatFileSnapshot {
    public static func read(_ url: URL) throws -> ChatFileAttachment {
        let path = url.path
        let components = url.pathComponents
        let comparablePath = path.precomposedStringWithCanonicalMapping.lowercased()
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
            .precomposedStringWithCanonicalMapping.lowercased()
        let protectedRoots = [home + "/library/application support/aides", home + "/library/keychains"]
        guard url.isFileURL, path.hasPrefix("/"), path.utf8.count <= 4_096, components.count <= 64,
              comparablePath != home, !home.hasPrefix(comparablePath.hasSuffix("/") ? comparablePath : comparablePath + "/"),
              !components.contains(where: ProjectFiles.isProtectedComponent),
              !protectedRoots.contains(where: { comparablePath == $0 || comparablePath.hasPrefix($0 + "/") }),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ChatAttachmentError.invalid
        }
        let attributes = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey])
        guard attributes.isSymbolicLink != true, attributes.isAliasFile != true else { throw ChatAttachmentError.invalid }

        let name = url.lastPathComponent
        let attachment: ChatFileAttachment
        if attributes.isDirectory == true {
            let entries = try ProjectFiles.list(path: ".", in: url)
            let limit = ChatFileAttachment.maximumFolderEntries
            attachment = ChatFileAttachment(name: name, entries: Array(entries.prefix(limit)), truncated: entries.count > limit)
        } else if attributes.isRegularFile == true {
            guard (attributes.fileSize ?? 0) <= ChatFileAttachment.maximumFileBytes else { throw ChatAttachmentError.text }
            do {
                guard let text = try ProjectFiles.read(path: name, in: url.deletingLastPathComponent()) else {
                    throw ChatAttachmentError.invalid
                }
                attachment = ChatFileAttachment(name: name, text: text)
            } catch ProjectFileError.invalidText {
                throw ChatAttachmentError.text
            }
        } else {
            throw ChatAttachmentError.invalid
        }
        try ChatFileAttachment.validate([attachment])
        return attachment
    }
}
