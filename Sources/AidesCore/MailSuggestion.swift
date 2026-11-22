import Foundation

public struct MailSuggestion: Codable, Sendable {
    public let to: String
    public let from: String?
    public let subject: String
    public let body: String

    public init(to: String, from: String? = nil, subject: String, body: String) {
        self.to = to
        self.from = from
        self.subject = subject
        self.body = body
    }
}
