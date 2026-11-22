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

        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw Failure.unavailable }
        let reader = descriptors[0], writer = descriptors[1]
        defer { close(reader) }
        guard fcntl(reader, F_SETFL, O_NONBLOCK) >= 0 else {
            close(writer)
            throw Failure.unavailable
        }

        let environment = [
            "HOME=\(scratch.path)", "TMPDIR=\(scratch.path)", "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL=C", "CI=1", "GIT_CONFIG_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0"
        ]
        let pid: pid_t
        do {
            pid = try spawn(
                executable: executable.path, arguments: arguments, directory: directory.path,
                environment: environment, reader: reader, writer: writer
            )
        } catch {
            close(writer)
            throw error
        }
        close(writer)

        var exitStatus: Int32 = 0
        var drained = false
        var leaderExited = false
        defer {
            if !leaderExited || !drained { kill(-pid, SIGKILL) }
            if !leaderExited {
                while waitpid(pid, &exitStatus, 0) < 0 && errno == EINTR {}
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            try Task.checkCancellation()
            if !drained {
                let count = buffer.withUnsafeMutableBytes { read(reader, $0.baseAddress, $0.count) }
                if count > 0 {
                    guard output.count + count <= 65_536 else { throw Failure.outputLimit }
                    output.append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    drained = true
                } else if errno != EAGAIN && errno != EINTR {
                    throw Failure.unavailable
                }
            }

            if !leaderExited {
                let exited = waitpid(pid, &exitStatus, WNOHANG)
                if exited == pid {
                    leaderExited = true
                    // A command is one execution, including descendants that inherited its output pipe.
                    kill(-pid, SIGKILL)
                } else if exited < 0 && errno != EINTR {
                    throw Failure.unavailable
                }
            }

            if leaderExited && drained {
                let signal = exitStatus & 0x7f
                let status = signal == 0 ? (exitStatus >> 8) & 0xff : 128 + signal
                return Result(status: status, output: String(decoding: output, as: UTF8.self))
            }
            guard clock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    private static func spawn(
        executable: String, arguments: [String], directory: String, environment: [String],
        reader: Int32, writer: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw Failure.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_addchdir_np(&actions, directory) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, writer, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, reader) == 0,
              posix_spawn_file_actions_addclose(&actions, writer) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw Failure.unavailable }

        var argv = ([executable] + arguments).map { strdup($0) }
        var envp = environment.map { strdup($0) }
        defer {
            for argument in argv { free(argument) }
            for variable in envp { free(variable) }
        }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { throw Failure.unavailable }
        argv.append(nil)
        envp.append(nil)
        var processID: pid_t = 0
        let status = argv.withUnsafeMutableBufferPointer { argv in
            envp.withUnsafeMutableBufferPointer { envp in
                posix_spawn(&processID, executable, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        guard status == 0, processID > 0 else { throw Failure.unavailable }
        return processID
    }
}
