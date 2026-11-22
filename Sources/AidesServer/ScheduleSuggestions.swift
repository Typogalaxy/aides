import AidesCore
import Foundation
import Vapor

extension AidesService {
    func acceptScheduleSuggestion(messageID: UUID) async throws -> AppState {
        try await change { state in
            if state.acceptedScheduleSuggestions?[messageID] != nil { return }
            guard let thread = state.app.threads.first(where: { thread in
                thread.archivedAt == nil && thread.messages.contains(where: { $0.id == messageID })
            }), let suggestion = thread.messages.first(where: { $0.id == messageID })?.scheduleSuggestion,
               suggestion.isValid(after: .now), let zone = TimeZone(identifier: suggestion.timeZone) else {
                throw Abort(.conflict, reason: "This suggestion is missing, expired, or no longer available.")
            }
            let profile = try Self.workModel(nil, kind: suggestion.kind, in: state)
            let schedule = WorkSchedule(
                title: suggestion.title, threadID: thread.id, projectID: thread.projectID,
                modelID: profile?.id, kind: suggestion.kind, repeatRule: suggestion.repeatRule,
                timeZone: zone, firstRun: suggestion.firstRun
            )
            state.app.schedules.append(schedule)
            state.acceptedScheduleSuggestions = (state.acceptedScheduleSuggestions ?? [:])
                .merging([messageID: schedule.id]) { old, _ in old }
            if let index = state.app.threads.firstIndex(where: { $0.id == thread.id }) {
                state.app.threads[index].messages.append(Message(
                    "Scheduled: \(suggestion.title)", role: .system
                ))
            }
        }
    }
}
