import Foundation

/// Plans local notifications within iOS's limit of 64 pending requests.
///
/// The app calls `plan` on launch, on foreground, after every check-off and from a background
/// refresh, then replaces all pending requests with the result. Because the nearest fire dates
/// always win, a medicine every hour can't starve tomorrow morning's habits forever, and the
/// rolling window keeps refilling.
public enum ReminderPlanner {
    public struct Input: Sendable {
        public var id: String
        public var history: HabitHistory
        public var rule: ReminderRule

        public init(id: String, history: HabitHistory, rule: ReminderRule) {
            self.id = id
            self.history = history
            self.rule = rule
        }
    }

    public struct Reminder: Sendable, Hashable {
        public var habitID: String
        public var day: DayKey
        public var slot: Int
        public var fireDate: Date
        /// Stable identifier so re-planning is idempotent.
        public var identifier: String { "\(habitID)|\(day.rawValue)|\(slot)" }
    }

    public static let systemLimit = 64

    public static func plan(_ inputs: [Input], now: Date, calendar: Calendar,
                            limit: Int = 60, horizonDays: Int = 10) -> [Reminder] {
        let today = DayKey(now, calendar: calendar)
        var out: [Reminder] = []

        for input in inputs {
            let slots = input.rule.slots
            guard !slots.isEmpty else { continue }
            let h = input.history

            for offset in 0..<horizonDays {
                let day = today.adding(days: offset)
                guard h.schedule.isDue(on: day, start: h.startDay), !h.skipped.contains(day) else { continue }

                let doneToday = h.count(on: day)
                if h.schedule.period != .day {
                    // Weekly/monthly: stop reminding once the current unit is done.
                    let r = StreakEngine.evaluate(h, today: day, firstWeekday: calendar.firstWeekday)
                    if r.isCurrentUnitDone { continue }
                    if doneToday > 0 { continue }   // already did one today
                }

                for (i, t) in slots.enumerated() {
                    // Slot i is satisfied once i+1 completions exist that day
                    // (take a 10:00 dose early at 09:30 → no 10:00 reminder).
                    if h.schedule.period == .day && doneToday > i { continue }
                    if h.schedule.period == .day && doneToday >= h.schedule.timesPerDay { break }
                    guard let fire = date(day, t, calendar), fire > now else { continue }
                    out.append(Reminder(habitID: input.id, day: day, slot: i, fireDate: fire))
                }
            }
        }

        out.sort { ($0.fireDate, $0.identifier) < ($1.fireDate, $1.identifier) }
        return Array(out.prefix(min(limit, systemLimit)))
    }

    /// Wall-clock time on a given day. A time skipped by a DST jump moves to the next valid time.
    static func date(_ day: DayKey, _ t: TimeOfDay, _ calendar: Calendar) -> Date? {
        let comps = DateComponents(hour: t.hour, minute: t.minute)
        let start = day.startDate(in: calendar)
        // Search from just before local midnight so a 00:00 slot is found on the same day.
        guard let d = calendar.nextDate(after: start.addingTimeInterval(-1), matching: comps,
                                        matchingPolicy: .nextTime) else { return nil }
        return DayKey(d, calendar: calendar) == day ? d : nil
    }
}
