import AidesCore
import CryptoKit
import Darwin
import Foundation

struct Host: Sendable {
    let directory: URL
    let bind: String
    let port: Int
    let mailFrom: String?
    let sendmailPath: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Aides", directoryHint: .isDirectory)
        let configuredDirectory = environment["AIDES_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? appSupport
        try FileManager.default.createDirectory(
            at: configuredDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        directory = configuredDirectory.resolvingSymlinksInPath().standardizedFileURL
        bind = environment["AIDES_HOST"] ?? "127.0.0.1"
        guard ["127.0.0.1", "::1"].contains(bind) else {
            throw StorageError("Aides binds to loopback. Use a private authenticated HTTPS proxy for another Mac.")
        }
        guard let port = Int(environment["AIDES_PORT"] ?? "8317"), (1024...65535).contains(port) else {
            throw StorageError("Invalid server port")
        }
        self.port = port
        if let path = environment["AIDES_SENDMAIL_PATH"], path.hasPrefix("/"),
           FileManager.default.isExecutableFile(atPath: path),
           let from = environment["AIDES_MAIL_FROM"], !from.isEmpty {
            sendmailPath = path
            mailFrom = from
        } else {
            sendmailPath = nil
            mailFrom = nil
        }
    }

    func createInvite() throws -> String {
        let folder = directory.appending(path: "invites", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date()
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) {
            if let time = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               now.timeIntervalSince(time) > 600 {
                try? FileManager.default.removeItem(at: file)
            }
        }
        let value = Self.token()
        try AppJSON.encoder().encode(now.addingTimeInterval(600)).write(to: invitation(value), options: .withoutOverwriting)
        return value
    }

    func consumeInvite(_ code: String) throws -> Bool {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard code.count == 64, code.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return false
        }
        let file = invitation(code)
        guard let data = try? Data(contentsOf: file),
              let expiresAt = try? AppJSON.decoder().decode(Date.self, from: data) else { return false }
        do { try FileManager.default.removeItem(at: file) } catch { return false }
        return expiresAt >= .now
    }

    func acquireProcessLock() throws -> Int32 {
        let path = directory.appending(path: "server.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StorageError("Cannot open server lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw StorageError("An Aides server already owns this data directory")
        }
        return descriptor
    }

    func saveAPIKey(_ key: String, for id: UUID) throws {
        let folder = directory.appending(path: "credentials", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appending(path: id.uuidString)
        try Data(key.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func apiKey(for id: UUID) throws -> String {
        let file = directory.appending(path: "credentials/\(id.uuidString)")
        guard let key = try? String(contentsOf: file, encoding: .utf8), !key.isEmpty else {
            throw StorageError("Model credential is unavailable. Configure the provider on the host.")
        }
        return key
    }

    func executable(for kind: ProviderKind) throws -> URL {
        let variable: String = switch kind {
        case .codex: "AIDES_CODEX_PATH"
        case .claudeCode: "AIDES_CLAUDE_CODE_PATH"
        default: throw StorageError("This provider does not use an official CLI.")
        }
        guard let path = ProcessInfo.processInfo.environment[variable], path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path) else {
            throw StorageError("Configure an official, signed-in CLI on the host using \(variable).")
        }
        return URL(fileURLWithPath: path)
    }

    private func invitation(_ code: String) -> URL {
        directory.appending(path: "invites/\(Self.digest(code))")
    }

    static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func token() -> String {
        (UUID().uuidString + UUID().uuidString).lowercased().replacingOccurrences(of: "-", with: "")
    }
}
