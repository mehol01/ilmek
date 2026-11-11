import Foundation

/// Pausing a habit (or every habit, "vacation") is a run of skipped days: neutral for streaks,
/// no reminders, and it syncs like any other log. Nothing new to store.
public enum Pause {
    /// Days to mark as skipped to pause from `from` through `through` (inclusive).
    public static func days(from: DayKey, through: DayKey) -> [DayKey] {
        guard from <= through else { return [] }
        return (0...from.days(to: through)).map { from.adding(days: $0) }
    }

    /// Last day of an ongoing pause: the run of skipped days starting at `today`, if it reaches
    /// past today. A lone skip of today alone is just a skip, not a pause.
    public static func pausedThrough(_ skipped: Set<DayKey>, today: DayKey) -> DayKey? {
        guard skipped.contains(today) else { return nil }
        var end = today
        while skipped.contains(end.adding(days: 1)) { end = end.adding(days: 1) }
        return end > today ? end : nil
    }
}
