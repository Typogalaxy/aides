import Darwin
import Foundation
import Vapor

struct ToolkitHostConfiguration: Sendable {
    let directory: URL

    func read(_ name: String) throws -> String? {
        let allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        guard (1...96).contains(name.utf8.count), name != ".", name != "..",
              name.utf8.allSatisfy(allowed.utf8.contains) else {
            throw Abort(.serviceUnavailable, reason: "Invalid Toolkit host configuration filename.")
        }
        let folder = directory.appending(path: "Toolkit", directoryHint: .isDirectory)
        let directory = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0 && errno == ENOENT { return nil }
        guard directory >= 0 else { throw permissionError }
        defer { close(directory) }
        var metadata = stat()
        guard fstat(directory, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else {
            throw permissionError
        }

        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if file < 0 && errno == ENOENT { return nil }
        guard file >= 0 else { throw permissionError }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fstat(file, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o077 == 0, (0...65_536).contains(metadata.st_size),
              let data = try handle.read(upToCount: 65_537), data.count <= 65_536,
              let text = String(data: data, encoding: .utf8) else { throw permissionError }
        return text
    }

    private var permissionError: Abort {
        Abort(.serviceUnavailable, reason: "Toolkit configuration must be private, local, and readable by the server operator.")
    }
}
