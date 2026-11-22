import AidesCore
import AidesExecution
import Foundation
import Vapor

extension AidesService {
    func sendSuggestedMail(messageID: UUID) async throws -> AppState {
        guard let from = host.mailFrom, host.sendmailPath != nil else {
            throw Abort(.conflict, reason: "The host has no local mail transport.")
        }
        return try await change { state in
            if state.acceptedMailSuggestions?[messageID] != nil { return }
            guard let thread = state.app.threads.first(where: { $0.role == .secretary }),
                  let suggestion = thread.messages.first(where: { $0.id == messageID })?.mailSuggestion,
                  suggestion.from == from else {
                throw Abort(.conflict, reason: "This mail draft is unavailable or the sender changed.")
            }
            do {
                _ = try PlainTextMail(from: from, to: suggestion.to, subject: suggestion.subject, body: suggestion.body)
                try CloudBoundary.validate(suggestion.body)
            } catch {
                throw Abort(.badRequest, reason: error.localizedDescription)
            }
            let task = WorkItem(title: "Send email to \(suggestion.to)", threadID: thread.id, kind: .mail)
            state.app.tasks.append(task)
            state.mail = (state.mail ?? [:]).merging([task.id: suggestion]) { existing, _ in existing }
            state.acceptedMailSuggestions = (state.acceptedMailSuggestions ?? [:])
                .merging([messageID: task.id]) { existing, _ in existing }
        }
    }
}
