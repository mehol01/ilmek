import Foundation

/// How often a habit is due. Default: once every day.
public struct Schedule: Codable, Hashable, Sendable {
    public enum Pattern: Codable, Hashable, Sendable {
        /// Every day.
        case everyDay
        /// Only on these Gregorian weekdays (1 = Sunday … 7 = Saturday).
        case weekdays(Set<Int>)
        /// Every N days, counted from the habit's start day.
        case everyNDays(Int)
        /// On these days of the month (1…31). A day past the month's end means its last day
        /// (31 → Feb 28/29), so "end of month" habits never silently disappear.
        case daysOfMonth(Set<Int>)
        /// N completions anywhere within the week.
        case timesPerWeek(Int)
        /// N completions anywhere within the month.
        case timesPerMonth(Int)
    }

    public var pattern: Pattern
    /// Completions needed on each due day (day-based patterns only), e.g. 8 glasses of water
    /// or 3 doses of a medicine. Ignored for `timesPerWeek` / `timesPerMonth`.
    public var timesPerDay: Int

    public init(pattern: Pattern = .everyDay, timesPerDay: Int = 1) {
        self.pattern = pattern
        self.timesPerDay = max(1, timesPerDay)
    }

    public static let daily = Schedule()

    /// The unit a streak is counted in.
    public enum Period: Sendable, Equatable { case day, week, month }

    public var period: Period {
        switch pattern {
        case .timesPerWeek: .week
        case .timesPerMonth: .month
        default: .day
        }
    }

    /// Completions needed per due unit (day, week or month).
    public var target: Int {
        switch pattern {
        case .timesPerWeek(let n), .timesPerMonth(let n): max(1, n)
        default: timesPerDay
        }
    }

    /// Whether a day-based habit is due on `day`. Period-based habits are "available" every day.
    public func isDue(on day: DayKey, start: DayKey) -> Bool {
        guard day >= start else { return false }
        switch pattern {
        case .everyDay, .timesPerWeek, .timesPerMonth:
            return true
        case .weekdays(let set):
            return set.isEmpty || set.contains(day.weekday)
        case .everyNDays(let n):
            return start.days(to: day) % max(1, n) == 0
        case .daysOfMonth(let set):
            let last = day.daysInMonth
            return set.contains { min($0, last) == day.day }
        }
    }
}

// MARK: - Reminders

public struct TimeOfDay: Codable, Hashable, Comparable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int = 0) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    public var minutesSinceMidnight: Int { hour * 60 + minute }

    public static func < (a: TimeOfDay, b: TimeOfDay) -> Bool {
        a.minutesSinceMidnight < b.minutesSinceMidnight
    }
}

public enum ReminderRule: Codable, Hashable, Sendable {
    case none
    /// Fixed times each due day.
    case times([TimeOfDay])
    /// Every `minutes` from `start` to `end` (inclusive), e.g. a medicine every 6 h, 08:00–22:00.
    case interval(minutes: Int, start: TimeOfDay, end: TimeOfDay)

    /// The reminder slots of one day, sorted and de-duplicated.
    public var slots: [TimeOfDay] {
        switch self {
        case .none:
            return []
        case .times(let t):
            return Array(Set(t)).sorted()
        case .interval(let minutes, let start, let end):
            let step = max(15, minutes)
            guard start <= end else { return [start] }
            return stride(from: start.minutesSinceMidnight, through: end.minutesSinceMidnight, by: step)
                .map { TimeOfDay(hour: $0 / 60, minute: $0 % 60) }
        }
    }
}
