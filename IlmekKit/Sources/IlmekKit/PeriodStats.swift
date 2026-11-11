import Foundation

/// The window the stats tab looks at. Rolling windows ending today, so "previous" is always
/// the same length right before it.
public enum StatsPeriod: String, CaseIterable, Sendable {
    case week, month, year, all

    public var length: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .year: 365
        case .all: nil
        }
    }
}

/// Numbers and series for one period of the stats tab.
public struct PeriodReport: Sendable, Equatable {
    public struct Bucket: Sendable, Equatable, Identifiable {
        public var start: DayKey
        public var days: Int
        /// Share of due check-ins done; nil when nothing was due.
        public var rate: Double?
        public var id: Int { start.rawValue }
    }

    public var range: ClosedRange<DayKey>
    public var rate: Double?
    /// Same-length window just before; nil for `.all` or when there's no history then.
    public var previousRate: Double?
    public var perfectDays: Int
    /// Days with anything due.
    public var activeDays: Int
    /// Habit check-offs that counted (capped at what was due).
    public var completed: Int
    /// 1 = Sunday … 7 = Saturday (Calendar weekday numbering).
    public var weekdayRates: [Int: Double]
    public var trend: [Bucket]

    /// - Parameters:
    ///   - summaries: one summary per day from `start` through `today`, oldest first.
    public init(summaries: [DaySummary], start: DayKey, today: DayKey, period: StatsPeriod,
                firstWeekday: Int = 2) {
        // `summaries` is expected to cover start…today; anything missing simply counts as no data.
        func summary(_ d: DayKey) -> DaySummary? {
            let i = start.days(to: d)
            return summaries.indices.contains(i) ? summaries[i] : nil
        }
        // An unfinished today is still in progress: it doesn't count against you yet.
        let t = summaries.last
        let todayClosed = t.map { $0.due == 0 || $0.done >= $0.due } ?? false
        func counts(_ d: DayKey) -> Bool { d != today || todayClosed }

        let lo = period.length.map { max(start, today.adding(days: -($0 - 1))) } ?? start
        range = lo...today

        var due = 0, done = 0, perfect = 0, active = 0
        var wdDue: [Int: Int] = [:], wdDone: [Int: Int] = [:]
        var d = lo
        while d <= today {
            if let s = summary(d), counts(d), s.due > 0 {
                due += s.due
                done += min(s.done, s.due)
                active += 1
                if s.done >= s.due { perfect += 1 }
                wdDue[d.weekday, default: 0] += s.due
                wdDone[d.weekday, default: 0] += min(s.done, s.due)
            }
            d = d.adding(days: 1)
        }
        rate = due > 0 ? Double(done) / Double(due) : nil
        completed = done
        perfectDays = perfect
        activeDays = active
        weekdayRates = wdDue.reduce(into: [:]) { out, e in out[e.key] = Double(wdDone[e.key] ?? 0) / Double(e.value) }

        if let n = period.length, lo > start {
            var pDue = 0, pDone = 0
            var p = max(start, lo.adding(days: -n))
            while p < lo {
                if let s = summary(p) { pDue += s.due; pDone += min(s.done, s.due) }
                p = p.adding(days: 1)
            }
            previousRate = pDue > 0 ? Double(pDone) / Double(pDue) : nil
        } else {
            previousRate = nil
        }

        // Trend: days for a week/month, weeks for a year, months (or weeks) for all time.
        let span = lo.days(to: today) + 1
        let step: Int? = switch period {
        case .week, .month: 1
        case .year: 7
        case .all: span <= 120 ? 7 : nil   // nil = calendar months
        }
        var buckets: [Bucket] = []
        func bucket(_ from: DayKey, _ to: DayKey) -> Bucket {
            var bd = 0, bn = 0, x = from
            while x <= to {
                if let s = summary(x), counts(x) { bd += s.due; bn += min(s.done, s.due) }
                x = x.adding(days: 1)
            }
            return Bucket(start: from, days: from.days(to: to) + 1, rate: bd > 0 ? Double(bn) / Double(bd) : nil)
        }
        if let step {
            // Weeks align to the calendar week so labels make sense.
            var from = step == 7 ? lo.startOfWeek(firstWeekday: firstWeekday) : lo
            while from <= today {
                let to = min(today, from.adding(days: step - 1))
                buckets.append(bucket(max(from, lo), to))
                from = from.adding(days: step)
            }
        } else {
            var from = lo.firstOfMonth
            while from <= today {
                let to = min(today, from.adding(days: from.daysInMonth - 1))
                buckets.append(bucket(max(from, lo), to))
                from = from.adding(days: from.daysInMonth)
            }
        }
        trend = buckets
    }
}

/// Hour-of-day histogram of check-ins (0…23).
public enum CheckInHours {
    public static func histogram(_ hours: [Int]) -> [Int] {
        var out = Array(repeating: 0, count: 24)
        for h in hours where (0..<24).contains(h) { out[h] += 1 }
        return out
    }

    /// The busiest part of the day, if there's enough to say anything.
    public static func peak(_ histogram: [Int]) -> DayPart? {
        let parts: [(DayPart, ClosedRange<Int>)] = [(.morning, 5...11), (.afternoon, 12...16)]
        var totals: [DayPart: Int] = [:]
        for (h, n) in histogram.enumerated() {
            let part = parts.first { $0.1.contains(h) }?.0 ?? .evening
            totals[part, default: 0] += n
        }
        let sum = totals.values.reduce(0, +)
        guard sum >= 5, let best = totals.max(by: { $0.value < $1.value }) else { return nil }
        return best.key
    }
}
