import Darwin
import Foundation

enum ProjectFileError: LocalizedError {
    case invalidPath
    case unavailableDirectory
    case unsupportedFile
    case invalidText
    case changed
    case io

    var errorDescription: String? {
        switch self {
        case .invalidPath: "Enter a relative project path that does not reference protected files."
        case .unavailableDirectory: "The project directory or file’s parent is unavailable."
        case .unsupportedFile: "The target must be a regular file within the project."
        case .invalidText: "Project file operations support UTF-8 text up to 64 KiB."
        case .changed: "The file changed since the proposal was prepared. Review a fresh proposal."
        case .io: "The project file operation could not complete."
        }
    }
}

enum ProjectFiles {
    static let maxBytes = 65_536

    static func validate(path: String) throws {
        _ = try components(path)
    }

    static func read(path: String, in root: URL) throws -> String? {
        try withParent(of: path, in: root) { directory, name in
            try contents(of: name, in: directory)?.text
        }
    }

    static func apply(path: String, expected: String?, replacement: String, in root: URL) throws {
        let replacementBytes = try textBytes(replacement)
        let expectedBytes = try expected.map(textBytes)
        try withParent(of: path, in: root) { directory, name in
            guard flock(directory, LOCK_EX) == 0 else { throw ProjectFileError.io }
            defer { flock(directory, LOCK_UN) }

            let original = try contents(of: name, in: directory)
            guard original?.data == expectedBytes else { throw ProjectFileError.changed }
            let temporary = ".aides-\(UUID().uuidString).tmp"
            let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ProjectFileError.io }
            defer {
                close(fd)
                unlinkat(directory, temporary, 0)
            }

            try writeAll(replacementBytes, to: fd)
            if let original, fchmod(fd, original.permissions) != 0 { throw ProjectFileError.io }
            guard fsync(fd) == 0 else { throw ProjectFileError.io }

            if let original {
                // Other Aides operations take the same directory lock. External editors
                // can still race the final compare and rename.
                guard let current = try contents(of: name, in: directory),
                      current.device == original.device, current.inode == original.inode,
                      current.data == original.data, current.permissions == original.permissions else {
                    throw ProjectFileError.changed
                }
                let writable = openat(directory, name, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard writable >= 0 else { throw ProjectFileError.io }
                close(writable)
                guard renameat(directory, temporary, directory, name) == 0 else { throw ProjectFileError.io }
            } else {
                guard renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) == 0 else {
                    if errno == EEXIST { throw ProjectFileError.changed }
                    throw ProjectFileError.io
                }
            }
            _ = fsync(directory)
        }
    }

    static func isProtectedComponent(_ name: String) -> Bool {
        let name = name.lowercased()
        let denied: Set<String> = [
            ".git", ".env", ".ssh", ".aws", ".azure", ".gnupg", ".kube", ".docker", ".config",
            ".codex", ".claude", ".aides", ".npmrc", ".netrc", ".pypirc", ".password-store",
            "secret", "secrets", "credential", "credentials", "keychain", "keychains", "certs",
            "certificates", "private_key", "auth.json", "invites", "server.lock", "aides.sqlite3", "aides.sqlite3-wal", "aides.sqlite3-shm"
        ]
        let extensions: Set<String> = [
            "pem", "key", "cert", "cer", "crt", "p12", "pfx", "keychain", "keychain-db", "kdbx", "mobileprovision"
        ]
        return denied.contains(name) || name.hasPrefix(".env.") || name.hasPrefix(".aides-") || name.hasPrefix("id_rsa") ||
            name.hasPrefix("id_ed25519") || name.hasPrefix("id_ecdsa") ||
            name.split(separator: ".").last.map { extensions.contains(String($0)) } == true
    }

    private struct FileContents {
        let text: String
        let data: Data
        let device: dev_t
        let inode: ino_t
        let permissions: mode_t
    }

    private static func components(_ path: String) throws -> [String] {
        guard path.utf8.count <= 1_024, !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ProjectFileError.invalidPath
        }
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 24, pieces.allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".." && component.utf8.count <= 255 &&
                !isProtectedComponent(String(component))
        }) else { throw ProjectFileError.invalidPath }
        return pieces.map(String.init)
    }

    private static func withParent<Result>(
        of path: String, in root: URL, operation: (CInt, String) throws -> Result
    ) throws -> Result {
        let pieces = try components(path)
        guard root.isFileURL, root.path.hasPrefix("/"), root.standardizedFileURL.path != "/" else {
            throw ProjectFileError.unavailableDirectory
        }
        let rootPieces = root.standardizedFileURL.path.split(separator: "/").map(String.init)
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ProjectFileError.unavailableDirectory }
        defer { close(directory) }
        for part in rootPieces + pieces.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ProjectFileError.unavailableDirectory }
            close(directory)
            directory = next
        }
        return try operation(directory, pieces[pieces.count - 1])
    }

    private static func textBytes(_ text: String) throws -> Data {
        guard text.utf8.count <= maxBytes, !text.utf8.contains(0) else { throw ProjectFileError.invalidText }
        return Data(text.utf8)
    }

    private static func contents(of name: String, in directory: CInt) throws -> FileContents? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw ProjectFileError.unsupportedFile }
            throw ProjectFileError.io
        }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw ProjectFileError.io }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else { throw ProjectFileError.unsupportedFile }
        guard metadata.st_size <= maxBytes else { throw ProjectFileError.invalidText }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in Darwin.read(fd, bytes.baseAddress, bytes.count) }
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ProjectFileError.io }
            guard data.count + count <= maxBytes else { throw ProjectFileError.invalidText }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw ProjectFileError.invalidText }
        return FileContents(
            text: text, data: data, device: metadata.st_dev, inode: metadata.st_ino,
            permissions: metadata.st_mode & 0o777
        )
    }

    private static func writeAll(_ data: Data, to fd: CInt) throws {
        try data.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, start.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ProjectFileError.io }
                offset += count
            }
        }
    }
}
