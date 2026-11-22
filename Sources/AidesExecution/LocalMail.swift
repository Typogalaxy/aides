import Darwin
import Foundation

public struct PlainTextMail: Sendable {
    public let from: String
    public let to: String
    public let subject: String
    public let body: String
    public let messageID: UUID

    public init(from: String, to: String, subject: String, body: String, messageID: UUID = UUID()) throws {
        guard Self.validAddress(from) else { throw LocalMailError.invalidFrom }
        guard Self.validAddress(to) else { throw LocalMailError.invalidRecipient }
        guard (1...512).contains(subject.utf8.count),
              !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !subject.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
              }) else {
            throw LocalMailError.invalidSubject
        }
        guard body.utf8.count <= 65_536, !body.utf8.contains(0) else { throw LocalMailError.invalidBody }
        self.from = from
        self.to = to
        self.subject = subject
        self.body = body
        self.messageID = messageID
    }

    private static func validAddress(_ address: String) -> Bool {
        guard address.utf8.count <= 254 else { return false }
        let halves = address.split(separator: "@", omittingEmptySubsequences: false)
        guard halves.count == 2,
              (1...64).contains(halves[0].utf8.count),
              let first = halves[0].utf8.first, isAlphanumeric(first),
              halves[0].split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ atom in
                  !atom.isEmpty && atom.utf8.allSatisfy { isAlphanumeric($0) || [43, 45, 95].contains($0) }
              }) else { return false }

        let labels = halves[1].split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            guard let first = label.utf8.first, let last = label.utf8.last,
                  label.utf8.count <= 63, isAlphanumeric(first), isAlphanumeric(last) else { return false }
            return label.utf8.allSatisfy { isAlphanumeric($0) || $0 == 45 }
        }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    func wireData(date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let domain = from.split(separator: "@").last ?? ""
        let headers = [
            "From: \(from)",
            "To: \(to)",
            "Subject: \(Self.encodeSubject(subject))",
            "Date: \(formatter.string(from: date))",
            "Message-ID: <\(messageID.uuidString.lowercased())@\(domain)>",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: base64"
        ].joined(separator: "\r\n")
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let encoded = Data(normalized.utf8).base64EncodedString(
            options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]
        )
        return Data("\(headers)\r\n\r\n\(encoded)\r\n".utf8)
    }

    private static func encodeSubject(_ subject: String) -> String {
        var words: [String] = []
        var bytes = Data()
        for scalar in subject.unicodeScalars {
            let fragment = String(scalar).utf8
            // Keep each UTF-8 scalar intact and leave room for the first header prefix.
            if bytes.count + fragment.count > 42 {
                words.append("=?UTF-8?B?\(bytes.base64EncodedString())?=")
                bytes.removeAll(keepingCapacity: true)
            }
            bytes.append(contentsOf: fragment)
        }
        words.append("=?UTF-8?B?\(bytes.base64EncodedString())?=")
        return words.joined(separator: "\r\n ")
    }
}

public enum MailSubmission: Sendable, Equatable {
    /// The local mail transport accepted the message. Recipient delivery is not verified.
    case acceptedByTransport
}

public enum LocalMailError: Error, Sendable, LocalizedError, Equatable {
    case invalidFrom
    case invalidRecipient
    case invalidSubject
    case invalidBody
    case invalidTransport
    case launchFailed
    case timedOut
    case interrupted
    case transportFailed(Int32)
    case transportSignalled(Int32)

    public var submissionMayHaveOccurred: Bool {
        switch self {
        case .timedOut, .interrupted, .transportFailed, .transportSignalled: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidFrom: "The sender must be a single email address."
        case .invalidRecipient: "Enter a single recipient email address."
        case .invalidSubject: "Enter a single-line subject of at most 512 UTF-8 bytes."
        case .invalidBody: "Enter plain text of at most 64 KiB without NUL bytes."
        case .invalidTransport: "Configure an absolute executable path for a local mail transport."
        case .launchFailed: "The local mail transport could not start."
        case .timedOut: "The mail transport timed out. Check its queue before trying again."
        case .interrupted: "The mail submission was interrupted. Check the transport queue before trying again."
        case .transportFailed(let status): "The mail transport exited with status \(status). Check its queue before trying again."
        case .transportSignalled(let signal): "The mail transport stopped on signal \(signal). Check its queue before trying again."
        }
    }
}

/// Submits one explicitly authorized message through a host-configured sendmail-compatible executable.
/// Every invocation is independent. A transport failure never triggers an automatic retry.
public struct LocalMail: Sendable {
    private let executable: URL
    private let timeout: Duration

    public init(executable: URL, timeout: Duration = .seconds(30)) throws {
        let manager = FileManager.default
        guard executable.isFileURL,
              executable.path.hasPrefix("/"),
              manager.isExecutableFile(atPath: executable.path),
              (try? executable.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              timeout > .zero, timeout <= .seconds(300) else {
            throw LocalMailError.invalidTransport
        }
        self.executable = executable
        self.timeout = timeout
    }

    public func send(_ message: PlainTextMail) async throws -> MailSubmission {
        try Task.checkCancellation()
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appending(path: "aides-mail-\(UUID().uuidString)", directoryHint: .isDirectory)
        let messageFile = directory.appending(path: "message")
        do {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw LocalMailError.launchFailed
        }
        defer { try? manager.removeItem(at: directory) }

        let input: FileHandle
        do {
            guard manager.createFile(
                atPath: messageFile.path, contents: message.wireData(date: .now), attributes: [.posixPermissions: 0o600]
            ) else { throw LocalMailError.launchFailed }
            let handle = try FileHandle(forReadingFrom: messageFile)
            // Once open, the child can read the data through stdin without a named spool file.
            try manager.removeItem(at: messageFile)
            input = handle
        } catch {
            throw LocalMailError.launchFailed
        }
        defer { try? input.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["-i", "-f", message.from, message.to]
        process.currentDirectoryURL = directory
        process.environment = [
            "HOME": manager.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": directory.path,
            "LC_ALL": "C"
        ]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exit = AsyncStream<MailExit>.makeStream(bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { child in
            exit.continuation.yield(MailExit(
                status: child.terminationStatus, signalled: child.terminationReason == .uncaughtSignal
            ))
            exit.continuation.finish()
        }

        try Task.checkCancellation()
        do {
            try process.run()
        } catch {
            throw LocalMailError.launchFailed
        }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: MailSubmission.self) { group in
                group.addTask {
                    for await state in exit.stream {
                        if state.signalled { throw LocalMailError.transportSignalled(state.status) }
                        guard state.status == 0 else { throw LocalMailError.transportFailed(state.status) }
                        return .acceptedByTransport
                    }
                    throw LocalMailError.interrupted
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw LocalMailError.timedOut
                }
                defer { group.cancelAll() }
                do {
                    guard let result = try await group.next() else { throw LocalMailError.interrupted }
                    return result
                } catch {
                    Self.stop(process)
                    if Task.isCancelled { throw LocalMailError.interrupted }
                    throw error
                }
            }
        } onCancel: {
            Self.stop(process)
        }
    }

    private static func stop(_ process: Process) {
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }
}

private struct MailExit: Sendable {
    let status: Int32
    let signalled: Bool
}
