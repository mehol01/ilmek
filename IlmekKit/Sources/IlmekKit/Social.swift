import Foundation

extension StreakEngine {
    /// Consecutive "full" days across all habits: every due habit done.
    /// Rest days (nothing due) are neutral; today counts only once complete.
    public static func perfectDayStreak(_ timelines: [HabitTimeline], today: DayKey,
                                        firstWeekday: Int = 2, limit: Int = 3650) -> Int {
        guard let first = timelines.map(\.firstDay).min() else { return 0 }
        var streak = 0
        let t = summary(timelines, on: today, firstWeekday: firstWeekday, forRecord: true)
        if t.due > 0 && t.done >= t.due { streak += 1 }
        var d = today.adding(days: -1)
        var steps = 0
        while d >= first && steps < limit {
            let s = summary(timelines, on: d, firstWeekday: firstWeekday, forRecord: true)
            if s.due > 0 {
                if s.done >= s.due { streak += 1 } else { break }
            }
            d = d.adding(days: -1)
            steps += 1
        }
        return streak
    }
}

/// Group join codes: 8 characters without look-alikes (0/O, 1/I), shown as `K7QF-29XM`.
public enum GroupCode {
    public static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    public static func random() -> String {
        var g = SystemRandomNumberGenerator()
        return String((0..<8).map { _ in alphabet.randomElement(using: &g)! })
    }

    /// Accepts any casing, spaces and dashes (Turkish "ı/i" included); nil if not a valid code.
    public static func normalize(_ input: String) -> String? {
        var out: [Character] = []
        for c in input {
            if c == "-" || c == " " || c == "\u{2011}" { continue }
            let up: Character = switch c {
            case "ı", "i", "İ": "I"
            default: Character(String(c).uppercased())
            }
            out.append(up)
        }
        guard out.count == 8, out.allSatisfy(alphabet.contains) else { return nil }
        return String(out)
    }

    public static func display(_ code: String) -> String {
        guard code.count == 8 else { return code }
        return "\(code.prefix(4))-\(code.suffix(4))"
    }
}

/// Compact scarf for friends: start day + 2 bytes per day (colour index, fraction 0…255).
/// A year is ~730 bytes.
public struct ScarfPayload: Equatable, Sendable {
    public var start: DayKey
    public var days: [(color: UInt8, fraction: UInt8)]

    public init(start: DayKey, days: [(color: UInt8, fraction: UInt8)]) {
        self.start = start
        self.days = days
    }

    /// Colour byte meaning "progress only, scarf not shared".
    public static let hiddenColor: UInt8 = 255

    /// Whether the sender shares their scarf colours (not just progress).
    public var hasColors: Bool { days.contains { $0.color != Self.hiddenColor } }

    public var last: DayKey { start.adding(days: max(days.count - 1, 0)) }

    public func entry(on day: DayKey) -> (color: UInt8, fraction: UInt8)? {
        let i = start.days(to: day)
        return days.indices.contains(i) ? days[i] : nil
    }

    public var data: Data {
        var d = Data()
        var raw = Int32(start.rawValue).bigEndian
        withUnsafeBytes(of: &raw) { d.append(contentsOf: $0) }
        for e in days { d.append(e.color); d.append(e.fraction) }
        return d
    }

    /// A little over three years of days; the app never sends more.
    public static let maxDays = 1100
    public static let maxBytes = 4 + 2 * maxDays

    /// Rejects anything that isn't a plausible scarf: this arrives from other people's phones.
    public init?(data: Data) {
        guard data.count >= 4, data.count <= Self.maxBytes, (data.count - 4) % 2 == 0 else { return nil }
        let bytes = [UInt8](data)
        let raw = bytes[0..<4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard raw <= 99_991_231, let start = DayKey(rawValue: Int(raw)),
              (2000...2200).contains(start.year) else { return nil }
        self.start = start
        days = stride(from: 4, to: bytes.count, by: 2).map { (bytes[$0], bytes[$0 + 1]) }
    }

    public static func == (a: ScarfPayload, b: ScarfPayload) -> Bool {
        a.start == b.start && a.days.count == b.days.count
            && zip(a.days, b.days).allSatisfy { $0.color == $1.color && $0.fraction == $1.fraction }
    }
}
