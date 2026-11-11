import Foundation

/// Headline numbers for the stats view, computed from consecutive daily summaries.
public struct ProgressStats: Sendable, Equatable {
    /// Current run of full days (rest days neutral, unfinished today doesn't break it).
    public var currentStreak: Int
    public var bestStreak: Int
    /// Share of due check-ins done in the last 7 / 30 days; nil when nothing was due.
    public var rate7: Double?
    public var rate30: Double?
    /// Days where everything due was done.
    public var perfectDays: Int

    /// `days` must be consecutive, oldest first, the last element being today.
    public init(days: [DaySummary]) {
        var best = 0, run = 0, perfect = 0
        for (i, d) in days.enumerated() {
            guard d.due > 0 else { continue }
            if d.done >= d.due {
                run += 1
                perfect += 1
                best = max(best, run)
            } else if i != days.count - 1 {
                run = 0
            }
        }
        bestStreak = best
        currentStreak = run
        perfectDays = perfect

        // An unfinished today is still in progress: leave it out of the rates.
        let todayDone = days.last.map { $0.due > 0 && $0.done >= $0.due } ?? false
        let closed = todayDone ? days[...] : days.dropLast()
        rate7 = Self.rate(closed.suffix(7))
        rate30 = Self.rate(closed.suffix(30))
    }

    static func rate(_ days: ArraySlice<DaySummary>) -> Double? {
        let due = days.reduce(0) { $0 + $1.due }
        guard due > 0 else { return nil }
        let done = days.reduce(0) { $0 + min($1.done, $1.due) }
        return Double(done) / Double(due)
    }
}

/// One square of a heatmap.
public enum HeatCell: Sendable, Equatable {
    /// Before tracking started or after today.
    case none
    /// Nothing was due.
    case rest
    /// 0…1 completion.
    case value(Double)
}

extension HabitTimeline {
    /// How this habit looked on `day`, for its own heatmap.
    public func cell(on day: DayKey, today: DayKey) -> HeatCell {
        guard day <= today, let h = history(on: day) else { return .none }
        let count = h.count(on: day)
        if h.skipped.contains(day) { return .rest }
        switch h.schedule.period {
        case .day:
            if day >= h.startDay && !h.schedule.isDue(on: day, start: h.startDay) {
                return count > 0 ? .value(1) : .rest
            }
            return .value(StreakEngine.fraction(h, on: day))
        case .week, .month:
            // Weekly/monthly goals aren't due on a specific day: mark days with a check-in.
            return count > 0 ? .value(1) : .rest
        }
    }
}
