import AidesCore
import Foundation

struct SecretaryResponse: Decodable, Sendable {
    let text: String
    let schedule: ScheduleSuggestion?

    static func instructions() -> String {
        let now = ISO8601DateFormatter().string(from: .now)
        let zone = TimeZone.current.identifier
        return """
        If the latest user message explicitly asks you to set a reminder or schedule work,
        and the timing is unambiguous, reply only with an object like:
        {"text":"A reply asking for confirmation","schedule":{"title":"Work to do","firstRun":"ISO 8601 timestamp with offset","timeZone":"IANA zone","repeatRule":"once","kind":"reminder"}}
        The allowed repeatRule values are once, daily, weekly. The kind values are reminder, analysis.
        The current time is \(now) and the server's local time zone is \(zone). Use the user's
        time zone when specified. A reminder or task remains a suggestion until the user confirms it.
        For any other request, use an ordinary reply. Ask if important timing is unclear.
        """
    }

    static func parse(_ value: String, now: Date = .now) -> SecretaryResponse {
        guard let result = try? AppJSON.decoder().decode(SecretaryResponse.self, from: Data(value.utf8)),
              !result.text.isEmpty else { return SecretaryResponse(text: value, schedule: nil) }
        if let schedule = result.schedule, schedule.isValid(after: now) {
            return result
        }
        return SecretaryResponse(text: result.text, schedule: nil)
    }
}
