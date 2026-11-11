import Foundation

/// A calendar day, independent of time zone and DST.
///
/// A log is stamped with the `DayKey` of the user's local day *at the moment it was logged*,
/// so travelling or a DST change never moves past entries to another day.
/// Day arithmetic is pure integer math (proleptic Gregorian), so it can't be skewed by
/// 23- or 25-hour days.
public struct DayKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        // Normalise through the day count so invalid input (Feb 30) can't exist.
        let (y, m, d) = Self.civil(fromDays: Self.days(fromCivil: year, month, day))
        self.year = y
        self.month = m
        self.day = d
    }

    /// The local day containing `date` in `calendar` (its time zone decides).
    ///
    /// Always read on the Gregorian calendar: a device set to the Buddhist, Islamic or Hebrew
    /// calendar would otherwise hand us its own year/month/day, which this type's day math
    /// (and the stored `yyyymmdd`) can't represent.
    public init(_ date: Date, calendar: Calendar) {
        let c = Self.gregorian(like: calendar).dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    static func gregorian(like calendar: Calendar) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var g = Calendar(identifier: .gregorian)
        g.timeZone = calendar.timeZone
        g.locale = calendar.locale
        g.firstWeekday = calendar.firstWeekday
        return g
    }

    private init(serial: Int) {
        (year, month, day) = Self.civil(fromDays: serial)
    }

    /// `yyyymmdd`, e.g. 20261105. Stable storage format (sortable, CloudKit-friendly).
    public var rawValue: Int { year * 10_000 + month * 100 + day }

    public init?(rawValue: Int) {
        let y = rawValue / 10_000, m = (rawValue / 100) % 100, d = rawValue % 100
        guard (1...12).contains(m), d >= 1, d <= Self.daysIn(year: y, month: m) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// Days since 1970-01-01.
    public var serial: Int { Self.days(fromCivil: year, month, day) }

    public func adding(days: Int) -> DayKey { DayKey(serial: serial + days) }

    /// Signed number of days from `self` to `other`.
    public func days(to other: DayKey) -> Int { other.serial - serial }

    /// Gregorian weekday, 1 = Sunday … 7 = Saturday (same as `Calendar.component(.weekday)`).
    public var weekday: Int {
        // 1970-01-01 was a Thursday (5).
        ((serial % 7) + 7 + 4) % 7 + 1
    }

    public var daysInMonth: Int { Self.daysIn(year: year, month: month) }

    public var firstOfMonth: DayKey { DayKey(year: year, month: month, day: 1) }

    /// First day of the week containing this day, given the calendar's `firstWeekday`.
    public func startOfWeek(firstWeekday: Int) -> DayKey {
        adding(days: -((weekday - firstWeekday + 7) % 7))
    }

    /// Local midnight of this day in `calendar`.
    public func startDate(in calendar: Calendar) -> Date {
        let g = Self.gregorian(like: calendar)
        // Noon always exists, even on days when a DST jump removes midnight.
        guard let noon = g.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else {
            return Date(timeIntervalSince1970: TimeInterval(serial) * 86_400)
        }
        return g.startOfDay(for: noon)
    }

    public static func < (a: DayKey, b: DayKey) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func today(calendar: Calendar = .current, now: Date = .now) -> DayKey {
        DayKey(now, calendar: calendar)
    }

    // MARK: - Civil date math (Howard Hinnant)

    static func days(fromCivil year: Int, _ month: Int, _ day: Int) -> Int {
        // Allow month overflow so DayKey(year:month:13…) normalises.
        var y = year + (month - 1).floorDiv(12)
        let m = (month - 1).floorMod(12) + 1
        y = m <= 2 ? y - 1 : y
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(fromDays days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    static func daysIn(year: Int, month: Int) -> Int {
        let start = days(fromCivil: year, month, 1)
        let next = days(fromCivil: year, month + 1, 1)
        return next - start
    }
}

extension Int {
    func floorDiv(_ d: Int) -> Int { (self >= 0 ? self : self - d + 1) / d }
    func floorMod(_ d: Int) -> Int { ((self % d) + d) % d }
}
