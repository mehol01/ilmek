import Foundation

/// Rules for the "Örgü" (knitting) tab: each day is one stitch.
///
/// - The user picks a yarn colour for the day; it can change until the day ends, then it's locked.
/// - How tight the stitch looks comes from the day's completion (0…1), so a perfect day is a
///   full, plump stitch and an empty day is a loose, faded one. Nothing is ever "unknitted".
/// - Rows are weeks, so the piece grows like a scarf — one row per week, ~52 rows a year.
public enum Knit {
    public static func canEditColor(of day: DayKey, today: DayKey) -> Bool {
        day == today
    }

    public enum StitchLook: Sendable, Equatable {
        /// Day hasn't come yet (or before the user started).
        case empty
        /// Today, still being knitted.
        case onNeedle(fraction: Double)
        /// Finished day.
        case knitted(fraction: Double)
    }

    public static func look(of day: DayKey, today: DayKey, started: DayKey, fraction: Double) -> StitchLook {
        if day < started || day > today { return .empty }
        let f = min(max(fraction, 0), 1)
        return day == today ? .onNeedle(fraction: f) : .knitted(fraction: f)
    }

    /// Week rows from the week containing `started` through the week containing `today`,
    /// newest last. Each row has 7 days starting at `firstWeekday`.
    public static func rows(started: DayKey, today: DayKey, firstWeekday: Int = 2) -> [[DayKey]] {
        guard started <= today else { return [] }
        var rows: [[DayKey]] = []
        var lo = started.startOfWeek(firstWeekday: firstWeekday)
        while lo <= today {
            rows.append((0..<7).map { lo.adding(days: $0) })
            lo = lo.adding(days: 7)
        }
        return rows
    }
}
