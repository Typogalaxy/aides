import Foundation

public enum RepeatRule: String, Codable, Sendable {
    case once, daily, weekly
}

public struct WorkSchedule: Codable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let threadID: UUID?
    public let projectID: UUID?
    public let modelID: UUID?
    public let kind: WorkKind
    public let repeatRule: RepeatRule
    public let timeZone: String
    public let firstRun: Date
    public var nextRun: Date?
    public var paused: Bool

    public init(
        title: String, threadID: UUID?, projectID: UUID?, modelID: UUID?, kind: WorkKind,
        repeatRule: RepeatRule, timeZone: TimeZone, firstRun: Date
    ) {
        id = UUID()
        self.title = title
        self.threadID = threadID
        self.projectID = projectID
        self.modelID = modelID
        self.kind = kind
        self.repeatRule = repeatRule
        self.timeZone = timeZone.identifier
        self.firstRun = firstRun
        nextRun = firstRun
        paused = false
    }

    public func following(_ date: Date) -> Date? {
        guard repeatRule != .once, let zone = TimeZone(identifier: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let days = repeatRule == .weekly ? 7 : 1
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: firstRun), to: date).day ?? 0
        let nextOffset = (max(0, offset) / days + 1) * days
        return calendar.date(byAdding: .day, value: nextOffset, to: firstRun)
    }
}
