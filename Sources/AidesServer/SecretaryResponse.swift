import AidesCore
import Foundation

struct SecretaryResponse: Decodable, Sendable {
    let text: String
    let schedule: ScheduleSuggestion?
    var mail: MailSuggestion? = nil

    static func instructions(mailAvailable: Bool) -> String {
        let now = ISO8601DateFormatter().string(from: .now)
        let zone = TimeZone.current.identifier
        let mailInstructions = mailAvailable ? """
        If the user explicitly asks to send a plain text email and provided the recipient address,
        return {"text":"Ask the user to confirm the draft","mail":{"to":"single user-provided address","subject":"subject","body":"plain text"}}.
        Ask if the address or intended message is unclear. Never claim the message was sent.
        """ : "Email transport on the server is unavailable; you can draft emails in plain text."
        return """
        \(mailInstructions)

        If the latest user message explicitly asks you to set a reminder or schedule work,
        and the timing is unambiguous, reply only with an object like:
        {"text":"A reply asking for confirmation","schedule":{"title":"Work to do","firstRun":"ISO 8601 timestamp with offset","timeZone":"IANA zone","repeatRule":"once","kind":"reminder"}}
        The allowed repeatRule values are once, daily, weekly. The kind values are reminder, analysis.
        The current time is \(now) and the server's local time zone is \(zone). Use the user's
        time zone when specified. A reminder or task remains a suggestion until the user confirms it.
        For any other request, use an ordinary reply. Ask if important timing is unclear.
        """
    }

    static func parse(_ value: String, mailFrom: String?, now: Date = .now) -> SecretaryResponse {
        guard let result = try? AppJSON.decoder().decode(SecretaryResponse.self, from: Data(value.utf8)),
              !result.text.isEmpty else { return SecretaryResponse(text: value, schedule: nil) }
        if let schedule = result.schedule, result.mail == nil, schedule.isValid(after: now) {
            return result
        }
        if let mail = result.mail, let mailFrom, result.schedule == nil,
           !mail.to.isEmpty, mail.to.utf8.count <= 254, !mail.subject.isEmpty, mail.subject.utf8.count <= 512,
           !mail.body.isEmpty, mail.body.utf8.count <= 16_384 {
            return SecretaryResponse(
                text: result.text, schedule: nil,
                mail: MailSuggestion(to: mail.to, from: mailFrom, subject: mail.subject, body: mail.body)
            )
        }
        return SecretaryResponse(text: result.text, schedule: nil)
    }
}
