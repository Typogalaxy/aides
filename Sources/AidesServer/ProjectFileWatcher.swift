import Foundation

struct ProjectFileSnapshot: Codable, Equatable, Sendable {
    struct Stamp: Codable, Equatable, Sendable {
        let modifiedMicroseconds: Int64
        let size: Int
    }

    let files: [String: Stamp]
}

struct ProjectFileChanges: Sendable {
    let created: [String]
    let modified: [String]
    let removed: [String]
    let total: Int
}

enum ProjectFileWatcher {
    static func snapshot(directory: String) async -> ProjectFileSnapshot? {
        let scan = Task.detached(priority: .utility) { scanDirectory(directory) }
        return await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
    }

    static func changes(
        from previous: ProjectFileSnapshot, to current: ProjectFileSnapshot, limit: Int = 12
    ) -> ProjectFileChanges {
        let created = current.files.keys.filter { previous.files[$0] == nil }.sorted()
        let modified = current.files.keys.filter { path in
            previous.files[path].map { $0 != current.files[path] } == true
        }.sorted()
        let removed = previous.files.keys.filter { current.files[$0] == nil }.sorted()
        let budget = max(0, limit)
        return ProjectFileChanges(
            created: Array(created.prefix(budget)),
            modified: Array(modified.prefix(max(0, budget - created.count))),
            removed: Array(removed.prefix(max(0, budget - created.count - modified.count))),
            total: created.count + modified.count + removed.count
        )
    }

    private static func scanDirectory(_ directory: String) -> ProjectFileSnapshot? {
        guard directory.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        guard root.path != "/", root.resolvingSymlinksInPath().path == root.path,
              (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                         .contentModificationDateKey, .fileSizeKey]
        var incomplete = false
        guard let paths = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                incomplete = true
                return false
            }
        ) else { return nil }

        let prefix = root.path + "/"
        let ignored = Set(["node_modules", "deriveddata"])
        var files: [String: ProjectFileSnapshot.Stamp] = [:]
        var visited = 0
        for case let item as URL in paths {
            visited += 1
            guard visited <= 2_000, !Task.isCancelled, item.path.hasPrefix(prefix) else { return nil }
            let name = item.lastPathComponent.lowercased()
            guard !ignored.contains(name), !ProjectFiles.isProtectedComponent(name) else {
                paths.skipDescendants()
                continue
            }
            guard let metadata = try? item.resourceValues(forKeys: keys) else { return nil }
            if metadata.isSymbolicLink == true || paths.level >= 4 {
                paths.skipDescendants()
            }
            let relative = String(item.path.dropFirst(prefix.count))
            guard metadata.isSymbolicLink != true, metadata.isRegularFile == true,
                  relative.utf8.count <= 1_024, !relative.contains(where: { $0.isNewline }),
                  let date = metadata.contentModificationDate, let size = metadata.fileSize,
                  let microseconds = Int64(exactly: (date.timeIntervalSince1970 * 1_000_000).rounded()) else { continue }
            files[relative] = .init(modifiedMicroseconds: microseconds, size: size)
        }

        guard !incomplete else { return nil }
        return ProjectFileSnapshot(files: files)
    }
}
