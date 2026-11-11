import Foundation

/// Where a habit sits in the day on the Today list, taken from its first reminder.
/// No stored field: changing a reminder moves the habit, and nothing new syncs.
public enum DayPart: Int, CaseIterable, Comparable, Sendable {
    case morning, afternoon, evening, anytime

    public init(_ rule: ReminderRule) {
        guard let first = rule.slots.first else { self = .anytime; return }
        switch first.hour {
        case 5..<12: self = .morning
        case 12..<17: self = .afternoon
        default: self = .evening   // 17:00–04:59
        }
    }

    /// Minutes since midnight of the first reminder, for ordering inside a part.
    public static func sortKey(_ rule: ReminderRule) -> Int {
        guard let first = rule.slots.first else { return .max }
        // Late-night reminders (00:00–04:59) belong to the end of the evening.
        return first.hour < 5 ? first.minutesSinceMidnight + 24 * 60 : first.minutesSinceMidnight
    }

    public static func < (a: DayPart, b: DayPart) -> Bool { a.rawValue < b.rawValue }
}
