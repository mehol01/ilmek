import Foundation

/// A schedule that was in effect from `from` until the next segment (or the current schedule).
public struct ScheduleSegment: Codable, Hashable, Sendable {
    public var from: DayKey
    public var schedule: Schedule

    public init(from: DayKey, schedule: Schedule) {
        self.from = from
        self.schedule = schedule
    }
}

/// A habit across all its schedule changes and its archive date.
///
/// Streaks use `current` (with carry-over). Anything that looks at a *past day* — the knit,
/// calendars, a friend's summary — asks `history(on:)`, so editing or archiving a habit
/// never changes how a finished day looks.
public struct HabitTimeline: Sendable {
    public var current: HabitHistory
    /// Older schedules, any order.
    public var past: [ScheduleSegment]
    /// First day the habit no longer counts (archive day). `nil` while active.
    public var endDay: DayKey?

    public init(current: HabitHistory, past: [ScheduleSegment] = [], endDay: DayKey? = nil) {
        self.current = current
        self.past = past.sorted { $0.from < $1.from }
        self.endDay = endDay
    }

    /// The history to judge `day` by, or `nil` if the habit didn't exist / was archived then.
    public func history(on day: DayKey) -> HabitHistory? {
        if let endDay, day >= endDay { return nil }
        if day >= current.startDay { return current }
        guard let seg = past.last(where: { $0.from <= day }) else { return nil }
        var h = current
        h.schedule = seg.schedule
        h.startDay = seg.from
        h.carryOver = 0
        h.carryBest = 0
        return h
    }

    public var firstDay: DayKey { past.first?.from ?? current.startDay }
}

extension StreakEngine {
    public static func summary(_ timelines: [HabitTimeline], on day: DayKey,
                               firstWeekday: Int = 2, forRecord: Bool = false) -> DaySummary {
        summary(timelines.compactMap { $0.history(on: day) }, on: day, firstWeekday: firstWeekday,
                forRecord: forRecord)
    }
}
