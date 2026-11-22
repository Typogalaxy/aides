import AidesCore
import Foundation
import Testing

struct ScheduleTests {
    @Test func oneTimeScheduleHasNoFollowingOccurrence() throws {
        let firstRun = try date("2026-11-22T09:00:00+11:00")
        let schedule = try makeSchedule(.once, firstRun: firstRun)

        #expect(schedule.nextRun == firstRun)
        #expect(!schedule.paused)
        #expect(schedule.following(firstRun) == nil)
        #expect(schedule.following(firstRun.addingTimeInterval(86_400)) == nil)
    }

    @Test(arguments: [
        ["2026-04-04T09:00:00+11:00", "2026-04-05T09:00:00+10:00", "2026-04-06T09:00:00+10:00"],
        ["2026-10-03T09:00:00+10:00", "2026-10-04T09:00:00+11:00", "2026-10-05T09:00:00+11:00"]
    ])
    func dailyScheduleRetainsMelbourneWallTimeAcrossDST(times: [String]) throws {
        let first = try date(times[0])
        let second = try date(times[1])
        let third = try date(times[2])
        let schedule = try makeSchedule(.daily, firstRun: first)

        #expect(schedule.following(first) == second)
        #expect(schedule.following(second) == third)
    }

    @Test func weeklyScheduleRetainsMelbourneWeekdayAndWallTime() throws {
        let first = try date("2026-10-03T09:00:00+10:00")
        let following = try date("2026-10-10T09:00:00+11:00")
        let schedule = try makeSchedule(.weekly, firstRun: first)

        #expect(schedule.following(first) == following)
    }

    @Test func dayAfterMissingDSTTimeReturnsToOriginalTime() throws {
        let first = try date("2026-10-03T02:30:00+10:00")
        let sundayAfterDSTChange = try date("2026-10-04T04:00:00+11:00")
        let monday = try date("2026-10-05T02:30:00+11:00")
        let schedule = try makeSchedule(.daily, firstRun: first)

        #expect(schedule.following(sundayAfterDSTChange) == monday)
    }

    @Test func overdueDailyReminderKeepsTodaysRepeatIfItHasNotHappened() throws {
        let first = try date("2026-11-19T09:00:00+11:00")
        let now = try date("2026-11-22T08:59:59+11:00")
        let today = try date("2026-11-22T09:00:00+11:00")
        let tomorrow = try date("2026-11-23T09:00:00+11:00")
        var schedule = try makeSchedule(.daily, firstRun: first)
        schedule.nextRun = try date("2026-11-20T09:00:00+11:00")

        #expect(schedule.following(now) == today)
        #expect(schedule.following(today) == tomorrow)
    }

    @Test func overdueWeeklyReminderKeepsTodaysRepeatIfItHasNotHappened() throws {
        let first = try date("2026-11-08T09:00:00+11:00")
        let now = try date("2026-11-22T08:59:59+11:00")
        let today = try date("2026-11-22T09:00:00+11:00")
        let nextWeek = try date("2026-11-29T09:00:00+11:00")
        var schedule = try makeSchedule(.weekly, firstRun: first)
        schedule.nextRun = try date("2026-11-15T09:00:00+11:00")

        #expect(schedule.following(now) == today)
        #expect(schedule.following(today) == nextWeek)
    }

    private func makeSchedule(_ rule: RepeatRule, firstRun: Date) throws -> WorkSchedule {
        let melbourne = try #require(TimeZone(identifier: "Australia/Melbourne"))
        return WorkSchedule(
            title: "Fixture reminder", threadID: nil, projectID: nil, modelID: nil,
            kind: .reminder, repeatRule: rule, timeZone: melbourne, firstRun: firstRun
        )
    }

    private func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }
}
