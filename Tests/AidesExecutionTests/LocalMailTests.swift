import Foundation
import Testing
@testable import AidesExecution

struct LocalMailTests {
    @Test(arguments: [
        "-X@example.test", "a@example.test,b@example.test", "Group: a@example.test;",
        "A Person <a@example.test>", "a@example.test\r\nBcc: b@example.test",
        "a..b@example.test", "a@-example.test", "a@example..test"
    ])
    func rejectsRecipientListsAndInjectedRecipients(address: String) {
        #expect(throws: LocalMailError.invalidRecipient) {
            try PlainTextMail(from: "sender@example.test", to: address, subject: "Confirmation", body: "Thanks")
        }
    }

    @Test func validatesOtherUserSuppliedFields() {
        #expect(throws: LocalMailError.invalidFrom) {
            try PlainTextMail(from: "sender@example.test\nCc: other@example.test", to: "one@example.test", subject: "Test", body: "")
        }
        #expect(throws: LocalMailError.invalidSubject) {
            try message(subject: "Confirmation\r\nBcc: other@example.test")
        }
        #expect(throws: LocalMailError.invalidSubject) {
            try message(subject: String(repeating: "x", count: 513))
        }
        #expect(throws: LocalMailError.invalidBody) {
            try message(body: "before\u{0}after")
        }
        #expect(throws: LocalMailError.invalidBody) {
            try message(body: String(repeating: "x", count: 65_537))
        }
    }

    @Test func preservesUTF8AndStableMessageIdentityInMIME() throws {
        let title = String(repeating: "聚餐确认 Café 🥗 ", count: 9)
        let mail = try message(subject: title, body: "第一行\n.\r\n第二行\rThird line")
        let wire = String(decoding: mail.wireData(date: Date(timeIntervalSince1970: 0)), as: UTF8.self)
        let sections = wire.components(separatedBy: "\r\n\r\n")
        try #require(sections.count == 2)
        let headers = sections[0].components(separatedBy: "\r\n")
        #expect(headers.contains("From: sender+project@example.test"))
        #expect(headers.contains("To: one@example.test"))
        #expect(headers.contains("Date: Thu, 01 Jan 1970 00:00:00 +0000"))
        #expect(headers.contains("Message-ID: <\(mail.messageID.uuidString.lowercased())@example.test>"))
        #expect(headers.contains("Content-Type: text/plain; charset=UTF-8"))
        #expect(headers.allSatisfy { $0.utf8.count <= 78 })
        let subjectFields = headers.filter { $0.hasPrefix("Subject: ") || $0.hasPrefix(" =?UTF-8?B?") }
        let words = try subjectFields.map { line in
            let encoded = line.replacingOccurrences(of: "Subject: ", with: "").trimmingCharacters(in: .whitespaces)
            let data = try #require(Data(base64Encoded: String(encoded.dropFirst("=?UTF-8?B?".count).dropLast(2))))
            return try #require(String(data: data, encoding: .utf8))
        }
        #expect(words.joined() == title)
        let decoded = try #require(Data(base64Encoded: sections[1], options: .ignoreUnknownCharacters))
        #expect(String(decoding: decoded, as: UTF8.self) == "第一行\r\n.\r\n第二行\r\nThird line")
    }

    @Test func submitsThroughOnlyTheConfiguredExecutable() async throws {
        let fixture = try MailFixture("""
            #!/bin/sh
            set -eu
            test "$#" = 4
            test "$1" = "-i"
            test "$2" = "-f"
            test "$3" = "sender+project@example.test"
            test "$4" = "one@example.test"
            test -z "${OPENAI_API_KEY:-}"
            test -z "${ANTHROPIC_API_KEY:-}"
            test ! -e message
            /bin/cat > "$0.input"
            """)
        let mail = try message()
        let result = try await LocalMail(executable: fixture.executable).send(mail)
        let captured = try String(contentsOf: fixture.sidecar("input"), encoding: .utf8)

        #expect(result == .acceptedByTransport)
        #expect(captured.contains("Message-ID: <\(mail.messageID.uuidString.lowercased())@example.test>"))
        #expect(captured.contains("Content-Transfer-Encoding: base64"))
    }

    @Test func reportsARejectedTransportWithoutTryingAgain() async throws {
        let fixture = try MailFixture("""
            #!/bin/sh
            printf '1' >> "$0.runs"
            printf '%s' 'Do not disclose the transport diagnostic' >&2
            exit 75
            """)
        await #expect(throws: LocalMailError.transportFailed(75)) {
            try await LocalMail(executable: fixture.executable).send(message())
        }
        let runs = try String(contentsOf: fixture.sidecar("runs"), encoding: .utf8)
        #expect(runs == "1")
        #expect(LocalMailError.transportFailed(75).submissionMayHaveOccurred)
    }

    @Test func expiresAStalledTransportWithoutTryingAgain() async throws {
        let fixture = try MailFixture("""
            #!/bin/sh
            exec /bin/sleep 30
            """)
        await #expect(throws: LocalMailError.timedOut) {
            try await LocalMail(executable: fixture.executable, timeout: .milliseconds(150)).send(message())
        }
        #expect(LocalMailError.timedOut.submissionMayHaveOccurred)
    }

    @Test func cancellationAfterLaunchReportsAnUncertainOutcome() async throws {
        let fixture = try MailFixture("""
            #!/bin/sh
            printf 'ready' > "$0.ready"
            exec /bin/sleep 30
            """)
        let transport = try LocalMail(executable: fixture.executable)
        let mail = try message()
        let job = Task { try await transport.send(mail) }
        defer { job.cancel() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: fixture.sidecar("ready").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: fixture.sidecar("ready").path))
        job.cancel()
        await #expect(throws: LocalMailError.interrupted) { try await job.value }
    }

    @Test func rejectsAMissingTransportBeforeSending() {
        #expect(throws: LocalMailError.invalidTransport) {
            try LocalMail(executable: URL(fileURLWithPath: "/no-aides-fake-mail-\(UUID().uuidString)"))
        }
        #expect(!LocalMailError.invalidTransport.submissionMayHaveOccurred)
        #expect(!LocalMailError.launchFailed.submissionMayHaveOccurred)
    }

    private func message(subject: String = "Confirmation", body: String = "Thank you.") throws -> PlainTextMail {
        try PlainTextMail(from: "sender+project@example.test", to: "one@example.test", subject: subject, body: body)
    }
}

private final class MailFixture {
    let executable: URL

    init(_ script: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "aides-mail-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        executable = directory.appending(path: "fake-sendmail")
        guard FileManager.default.createFile(
            atPath: executable.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    deinit { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

    func sidecar(_ suffix: String) -> URL { executable.appendingPathExtension(suffix) }
}
