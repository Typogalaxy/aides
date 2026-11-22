import AidesCore
import Darwin
import Foundation
import Testing

@Test func deviceFileMovesRejectSymlinksAndNeverReplaceExistingFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source.txt")
    let existing = directory.appending(path: "existing.txt")
    try Data("source".utf8).write(to: source)
    try Data("existing".utf8).write(to: existing)
    try FileManager.default.createSymbolicLink(at: directory.appending(path: "alias.txt"), withDestinationURL: source)
    try Data("sensitive".utf8).write(to: directory.appending(path: ".env"))
    #expect(try ProjectFiles.list(path: ".", in: directory) == ["existing.txt", "source.txt"])
    #expect(throws: (any Error).self) {
        try ProjectFiles.move(path: "source.txt", to: "existing.txt", in: directory)
    }
    #expect(throws: (any Error).self) {
        try ProjectFiles.read(path: "alias.txt", in: directory)
    }
    #expect(throws: (any Error).self) {
        try ProjectFiles.read(path: ".env", in: directory)
    }
    try ProjectFiles.move(path: "source.txt", to: "moved.txt", in: directory)
    #expect(try ProjectFiles.read(path: "moved.txt", in: directory) == "source")
    #expect(try ProjectFiles.read(path: "source.txt", in: directory) == nil)
    #expect(try ProjectFiles.read(path: "existing.txt", in: directory) == "existing")
}

@Test func applyingAProposalRequiresExactCurrentBytes() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try ProjectFiles.apply(path: "file.txt", expected: nil, replacement: "v1", in: directory)
    #expect(throws: (any Error).self) {
        try ProjectFiles.apply(path: "file.txt", expected: "stale", replacement: "v2", in: directory)
    }
    #expect(try ProjectFiles.read(path: "file.txt", in: directory) == "v1")
    try ProjectFiles.apply(path: "file.txt", expected: "v1", replacement: "v2", in: directory)
    #expect(try ProjectFiles.read(path: "file.txt", in: directory) == "v2")
}

@Test func protectedProjectRootsCannotBeReadThroughRelativeNames() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let protected = directory.appending(path: ".kube")
    try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("synthetic credentials".utf8).write(to: protected.appending(path: "config"))
    #expect(throws: (any Error).self) { try ProjectFiles.read(path: "config", in: protected) }
    #expect(throws: (any Error).self) { try ProjectFiles.list(path: ".", in: protected) }
}

@Test func replacingTextPreservesExtendedFileAttributes() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "file.txt")
    try Data("old".utf8).write(to: file)
    let name = "com.typogalaxy.aides.test"
    let marker = [UInt8]("fixture".utf8)
    try #require(marker.withUnsafeBytes { setxattr(file.path, name, $0.baseAddress, $0.count, 0, 0) } == 0)
    try ProjectFiles.apply(path: "file.txt", expected: "old", replacement: "new", in: directory)
    var readBack = [UInt8](repeating: 0, count: marker.count)
    #expect(readBack.withUnsafeMutableBytes { getxattr(file.path, name, $0.baseAddress, $0.count, 0, 0) } == marker.count)
    #expect(readBack == marker)
}
