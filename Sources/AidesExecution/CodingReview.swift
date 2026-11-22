import Darwin
import Foundation

public enum CodingReviewProvider: String, Codable, Sendable {
    case codex
    case claudeCode
}

/// An optional, report-only call to an official CLI already configured on this host.
/// The application passes only material the user has authorized for this provider.
public struct CodingReviewRequest: Sendable {
    public let provider: CodingReviewProvider
    public let executable: URL
    public let model: String
    public let approvedInput: String

    public init(provider: CodingReviewProvider, executable: URL, model: String, approvedInput: String) {
        self.provider = provider
        self.executable = executable
        self.model = model
        self.approvedInput = approvedInput
    }

    fileprivate func validate() throws {
        guard executable.isFileURL,
              executable.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable.path),
              (1...128).contains(model.utf8.count),
              let first = model.utf8.first, Self.isAlphanumeric(first),
              model.utf8.allSatisfy({ Self.isAlphanumeric($0) || [45, 46, 95, 58].contains($0) }) else {
            throw ModelExecutionError.invalidConfiguration
        }
        guard !approvedInput.isEmpty else { throw ModelExecutionError.invalidConfiguration }
        guard approvedInput.utf8.count <= 262_144 else { throw ModelExecutionError.inputLimit }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    fileprivate var arguments: [String] {
        switch provider {
        case .codex:
            [
                "exec", "--ignore-user-config", "--strict-config", "--ephemeral",
                "--skip-git-repo-check", "--model", model, "--color", "never",
                "-c", "default_permissions=\"aides_report\"",
                "-c", "permissions.aides_report.filesystem={}",
                "-c", "permissions.aides_report.network.enabled=false",
                "-c", "web_search=\"disabled\"", "-c", "mcp_servers={}",
                "-c", "project_doc_max_bytes=0",
                "--disable", "shell_tool", "--disable", "apps",
                "--disable", "computer_use", "--disable", "browser_use",
                "--disable", "browser_use_external", "--disable", "plugins",
                "--disable", "hooks", "--disable", "daemon_auto_start",
                "-"
            ]
        case .claudeCode:
            [
                "-p", "--restricted", "--safe-mode", "--tools", "",
                "--disallowedTools", "*", "--strict-mcp-config", "--no-chrome",
                "--disable-slash-commands", "--no-session-persistence",
                "--max-turns", "1", "--model", model
            ]
        }
    }
}

public struct CodingReviewClient: Sendable {
    private let timeout: Duration

    public init() {
        self.init(timeout: .seconds(180))
    }

    init(timeout: Duration) {
        self.timeout = timeout
    }

    public func generate(_ request: CodingReviewRequest) async throws -> ModelOutput {
        try Task.checkCancellation()
        try request.validate()

        let root = FileManager.default.temporaryDirectory
            .appending(path: "aides-review-\(UUID().uuidString)", directoryHint: .isDirectory)
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        let input = root.appending(path: "input")
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ModelExecutionError.unavailable
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let source: FileHandle
        do {
            try FileManager.default.createDirectory(
                at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
            guard FileManager.default.createFile(
                atPath: input.path, contents: Data(request.approvedInput.utf8), attributes: [.posixPermissions: 0o600]
            ) else { throw ModelExecutionError.unavailable }
            source = try FileHandle(forReadingFrom: input)
            // Keep the approved material reachable only via stdin while the CLI is running.
            try FileManager.default.removeItem(at: input)
        } catch {
            throw ModelExecutionError.unavailable
        }
        defer { try? source.close() }

        try Task.checkCancellation()
        let result = try await run(request, work: work, input: source)
        guard let text = String(data: result, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw ModelExecutionError.unexpectedResponse
        }
        return ModelOutput(text: text, inputTokens: nil, outputTokens: nil)
    }

    private func run(_ request: CodingReviewRequest, work: URL, input: FileHandle) async throws -> Data {
        let pipe = Pipe()
        let exit = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.currentDirectoryURL = work
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": work.path,
            "CI": "1"
        ]
        process.standardInput = input
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = {
            exit.continuation.yield($0.terminationStatus)
            exit.continuation.finish()
        }

        do {
            try process.run()
        } catch {
            throw ModelExecutionError.unavailable
        }

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    var data = Data()
                    for try await byte in pipe.fileHandleForReading.bytes {
                        guard data.count < 1_048_576 else { throw ModelExecutionError.outputLimit }
                        data.append(byte)
                    }
                    for await status in exit.stream {
                        guard status == 0 else { throw ModelExecutionError.unavailable }
                        return data
                    }
                    try Task.checkCancellation()
                    throw ModelExecutionError.unavailable
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ModelExecutionError.unavailable
                }

                defer { group.cancelAll() }
                do {
                    guard let value = try await group.next() else { throw ModelExecutionError.unavailable }
                    try Task.checkCancellation()
                    return value
                } catch {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    try Task.checkCancellation()
                    if let error = error as? ModelExecutionError { throw error }
                    throw ModelExecutionError.unavailable
                }
            }
        } onCancel: {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
