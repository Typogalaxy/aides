import Darwin
import Foundation

public struct ToolkitCommandProcess: Sendable {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
    }

    public enum Failure: Error {
        case timeout, outputLimit, unavailable
    }

    public static func run(
        executable: URL, arguments: [String], directory: URL, timeout: Duration
    ) async throws -> Result {
        try Task.checkCancellation()
        let scratch = FileManager.default.temporaryDirectory.appending(path: "aides-command-\(UUID())")
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: scratch) }

        let pipe = Pipe()
        let exit = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = [
            "HOME": scratch.path, "TMPDIR": scratch.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C", "CI": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = {
            exit.continuation.yield($0.terminationStatus)
            exit.continuation.finish()
        }
        try process.run()

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Result.self) { group in
                group.addTask {
                    var data = Data()
                    for try await byte in pipe.fileHandleForReading.bytes {
                        guard data.count < 65_536 else { throw Failure.outputLimit }
                        data.append(byte)
                    }
                    for await status in exit.stream {
                        try Task.checkCancellation()
                        return Result(status: status, output: String(decoding: data, as: UTF8.self))
                    }
                    throw Failure.unavailable
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw Failure.timeout
                }
                defer { group.cancelAll() }
                do {
                    guard let result = try await group.next() else { throw Failure.unavailable }
                    return result
                } catch {
                    stop(process)
                    throw error
                }
            }
        } onCancel: {
            stop(process)
        }
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        // Only signal a group when its leader is the launched executable.
        kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
    }
}
