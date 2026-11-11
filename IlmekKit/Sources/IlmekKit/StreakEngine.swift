import Foundation

/// Everything the engine needs to know about one habit. Pure value — no persistence.
public struct HabitHistory: Sendable {
    public var schedule: Schedule
    public var startDay: DayKey
    /// Completions per day (already summed and de-duplicated by the caller).
    public var counts: [DayKey: Int]
    /// Days the user explicitly skipped (sick, travelling…). A skip never breaks a streak
    /// and never extends it.
    public var skipped: Set<DayKey>
    /// Streak carried over from before the last schedule change. Editing a habit's frequency
    /// moves `startDay` to the edit day and stores the streak so far here, so changing
    /// "every day" to "3× a week" never rewrites — or breaks — past days.
    public var carryOver: Int
    public var carryBest: Int

    public init(schedule: Schedule = .daily, startDay: DayKey,
                counts: [DayKey: Int] = [:], skipped: Set<DayKey> = [],
                carryOver: Int = 0, carryBest: Int = 0) {
        self.schedule = schedule
        self.startDay = startDay
        self.counts = counts
        self.skipped = skipped
        self.carryOver = carryOver
        self.carryBest = carryBest
    }

    public func count(on day: DayKey) -> Int { counts[day] ?? 0 }
}

public enum UnitStatus: Sendable, Equatable {
    case done, skipped, missed
    /// The unit that contains today and isn't complete yet. Never breaks a streak.
    case pending
    /// Not due (e.g. Tuesday for a Mon/Wed/Fri habit, or before the start day).
    case notDue
}

public struct StreakResult: Sendable, Equatable {
    public var current: Int
    public var best: Int
    public var unit: Schedule.Period
    /// Completions in the unit containing today, and how many are needed.
    public var progress: Int
    public var target: Int
    /// Whether today itself is a due day (always true for weekly/monthly habits).
    public var isDueToday: Bool

    public var isCurrentUnitDone: Bool { progress >= target }
}

public enum StreakEngine {
    /// Evaluates a habit's streak as of `today`.
    ///
    /// Rules:
    /// - A due unit with `count >= target` extends the streak by 1.
    /// - A skipped unit is neutral. A missed unit resets to 0.
    /// - The unit containing today is pending until it's done, so an unfinished morning
    ///   never shows a broken streak.
    /// - For weekly/monthly habits, the first (partial) unit can't break the streak.
    public static func evaluate(_ h: HabitHistory, today: DayKey, firstWeekday: Int = 2) -> StreakResult {
        var current = h.carryOver, best = max(h.carryBest, h.carryOver)
        for status in unitStatuses(h, through: today, firstWeekday: firstWeekday) {
            switch status {
            case .done:
                current += 1
                best = max(best, current)
            case .missed:
                current = 0
            case .skipped, .pending, .notDue:
                break
            }
        }

        let s = h.schedule
        let progress: Int
        switch s.period {
        case .day:
            progress = h.count(on: today)
        case .week, .month:
            let (lo, hi) = unitRange(containing: today, period: s.period, firstWeekday: firstWeekday)
            progress = sum(h, from: max(lo, h.startDay), to: hi)
        }
        return StreakResult(current: current, best: best, unit: s.period,
                            progress: progress, target: s.target,
                            isDueToday: s.isDue(on: today, start: h.startDay))
    }

    /// Status of each unit from the habit's start through `today`, oldest first.
    public static func unitStatuses(_ h: HabitHistory, through today: DayKey,
                                    firstWeekday: Int = 2) -> [UnitStatus] {
        guard h.startDay <= today else { return [] }
        let s = h.schedule

        switch s.period {
        case .day:
            var out: [UnitStatus] = []
            out.reserveCapacity(h.startDay.days(to: today) + 1)
            var d = h.startDay
            while d <= today {
                out.append(dayStatus(h, d, isToday: d == today))
                d = d.adding(days: 1)
            }
            return out

        case .week, .month:
            var out: [UnitStatus] = []
            var (lo, hi) = unitRange(containing: h.startDay, period: s.period, firstWeekday: firstWeekday)
            var isFirst = true
            while lo <= today {
                let total = sum(h, from: max(lo, h.startDay), to: min(hi, today))
                let containsToday = today <= hi
                let anySkip = h.skipped.contains { $0 >= lo && $0 <= hi }
                if total >= s.target {
                    out.append(.done)
                } else if containsToday {
                    out.append(.pending)
                } else if anySkip {
                    out.append(.skipped)
                } else if isFirst && lo < h.startDay {
                    out.append(.notDue)   // partial first unit: no penalty
                } else {
                    out.append(.missed)
                }
                isFirst = false
                lo = hi.adding(days: 1)
                hi = unitRange(containing: lo, period: s.period, firstWeekday: firstWeekday).1
            }
            return out
        }
    }

    /// Status of a single day for day-based habits (used for calendars & heatmaps).
    public static func dayStatus(_ h: HabitHistory, _ day: DayKey, isToday: Bool) -> UnitStatus {
        guard h.schedule.isDue(on: day, start: h.startDay) else { return .notDue }
        if h.count(on: day) >= h.schedule.timesPerDay { return .done }
        if h.skipped.contains(day) { return .skipped }
        return isToday ? .pending : .missed
    }

    /// 0…1 completion of `day` for a day-based habit; for weekly/monthly habits, whether
    /// anything was logged that day.
    public static func fraction(_ h: HabitHistory, on day: DayKey) -> Double {
        let c = h.count(on: day)
        // Days before the current schedule took effect: show what was logged.
        if day < h.startDay { return c > 0 ? 1 : 0 }
        switch h.schedule.period {
        case .day:
            guard h.schedule.isDue(on: day, start: h.startDay) else { return 0 }
            return min(1, Double(c) / Double(h.schedule.timesPerDay))
        case .week, .month:
            return c > 0 ? 1 : 0
        }
    }

    // MARK: - Helpers

    static func unitRange(containing day: DayKey, period: Schedule.Period,
                          firstWeekday: Int) -> (DayKey, DayKey) {
        switch period {
        case .day:
            return (day, day)
        case .week:
            let lo = day.startOfWeek(firstWeekday: firstWeekday)
            return (lo, lo.adding(days: 6))
        case .month:
            let lo = day.firstOfMonth
            return (lo, lo.adding(days: day.daysInMonth - 1))
        }
    }

    static func sum(_ h: HabitHistory, from lo: DayKey, to hi: DayKey) -> Int {
        guard lo <= hi else { return 0 }
        // Iterate the dictionary when it's smaller than the range (long-lived habits).
        if h.counts.count < lo.days(to: hi) + 1 {
            return h.counts.reduce(0) { $1.key >= lo && $1.key <= hi ? $0 + $1.value : $0 }
        }
        var total = 0, d = lo
        while d <= hi { total += h.count(on: d); d = d.adding(days: 1) }
        return total
    }
}

// MARK: - Daily summary (what friends see in a group)

public struct DaySummary: Codable, Hashable, Sendable {
    public var done: Int
    public var due: Int
    public init(done: Int, due: Int) { self.done = done; self.due = due }
    public var fraction: Double { due == 0 ? 0 : Double(done) / Double(due) }
}

extension StreakEngine {
    /// How many of today's due habits are complete. Weekly/monthly habits count as due
    /// today only until their unit is done; once done they count as done.
    ///
    /// `forRecord` judges a day after the fact (perfect-day streak, stats, heatmaps, scarf): a
    /// weekly/monthly habit that is still on track doesn't spoil a day. It counts as done on a
    /// day it was done, and against a day only when that day closes its unit short of the target.
    /// Without it, "3 runs a week" made every Monday and Tuesday an imperfect day.
    public static func summary(_ habits: [HabitHistory], on day: DayKey,
                               firstWeekday: Int = 2, forRecord: Bool = false) -> DaySummary {
        var done = 0, due = 0
        for h in habits where h.schedule.isDue(on: day, start: h.startDay) {
            // A skipped (or paused) habit isn't due that day, unless it was done anyway.
            if h.skipped.contains(day) && h.count(on: day) == 0 { continue }
            switch h.schedule.period {
            case .day:
                due += 1
                if h.count(on: day) >= h.schedule.timesPerDay { done += 1 }
            case .week, .month:
                // Progress of the unit up to and including `day` (O(unit), not O(history)).
                let (lo, hi) = unitRange(containing: day, period: h.schedule.period, firstWeekday: firstWeekday)
                let progress = sum(h, from: max(lo, h.startDay), to: day)
                if forRecord {
                    if h.count(on: day) > 0 { due += 1; done += 1 }
                    else if day == hi && progress < h.schedule.target { due += 1 }
                    continue
                }
                // Only show it in today's list if it was finished today or still open.
                if progress >= h.schedule.target {
                    if h.count(on: day) > 0 { due += 1; done += 1 }
                } else {
                    due += 1
                }
            }
        }
        return DaySummary(done: done, due: due)
    }
}
