import Foundation
import IlmekKit

extension Schedule {
    /// Short human description, e.g. "Her gün", "Pzt, Çar, Cum", "Haftada 3 kez".
    var summary: String {
        let perDay = timesPerDay > 1 ? String(localized: " · günde \(timesPerDay) kez") : ""
        switch pattern {
        case .everyDay:
            return String(localized: "Her gün") + perDay
        case .weekdays(let set):
            if set.count == 7 || set.isEmpty { return String(localized: "Her gün") + perDay }
            if set == [2, 3, 4, 5, 6] { return String(localized: "Hafta içi") + perDay }
            if set == [1, 7] { return String(localized: "Hafta sonu") + perDay }
            let names = Calendar.current.shortWeekdaySymbols
            return Weekdays.ordered.filter(set.contains).map { names[$0 - 1] }
                .joined(separator: ", ") + perDay
        case .everyNDays(let n):
            return String(localized: "\(n) günde bir") + perDay
        case .daysOfMonth(let set):
            let days = set.sorted().map { $0 >= 31 ? String(localized: "ay sonu") : "\($0)" }
            return String(localized: "Her ayın \(days.joined(separator: ", ")). günü") + perDay
        case .timesPerWeek(let n):
            return String(localized: "Haftada \(n) kez")
        case .timesPerMonth(let n):
            return String(localized: "Ayda \(n) kez")
        }
    }

    var unitWord: String {
        switch period {
        case .day: String(localized: "gün")
        case .week: String(localized: "hafta")
        case .month: String(localized: "ay")
        }
    }
}

enum Weekdays {
    /// Gregorian weekday numbers in the user's calendar order (Monday first in Turkey).
    static var ordered: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }
}

extension TimeOfDay {
    init(_ date: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        self.init(hour: c.hour ?? 9, minute: c.minute ?? 0)
    }

    var date: Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
    }

    var formatted: String { date.formatted(date: .omitted, time: .shortened) }
}
