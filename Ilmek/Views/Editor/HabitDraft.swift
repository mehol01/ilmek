import Foundation
import IlmekKit

/// Editable copy of a habit. The model is only touched on save, in one transaction.
struct HabitDraft {
    enum PatternKind: String, CaseIterable, Identifiable {
        case everyDay, weekdays, timesPerWeek, everyNDays, daysOfMonth, timesPerMonth
        var id: String { rawValue }

        var title: String {
            switch self {
            case .everyDay: String(localized: "Her gün")
            case .weekdays: String(localized: "Haftanın belirli günleri")
            case .timesPerWeek: String(localized: "Haftada birkaç kez")
            case .everyNDays: String(localized: "Birkaç günde bir")
            case .daysOfMonth: String(localized: "Ayın belirli günleri")
            case .timesPerMonth: String(localized: "Ayda birkaç kez")
            }
        }

        var isDayBased: Bool { self != .timesPerWeek && self != .timesPerMonth }
    }

    enum ReminderKind: String, CaseIterable, Identifiable {
        case none, times, interval
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: String(localized: "Yok")
            case .times: String(localized: "Belirli saatler")
            case .interval: String(localized: "Aralıklı")
            }
        }
    }

    var name = ""
    var emoji = "✨"
    var color: YarnColor = .terracotta
    var isMedication = false
    var dose = ""
    var isShared = true

    var pattern: PatternKind = .everyDay
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    var timesPerWeek = 3
    var everyN = 2
    var monthDays: Set<Int> = [1]
    var timesPerMonth = 4
    var timesPerDay = 1

    var reminderKind: ReminderKind = .none
    var times: [Date] = [TimeOfDay(hour: 9).date]
    var intervalHours = 8
    var intervalStart = TimeOfDay(hour: 8).date
    var intervalEnd = TimeOfDay(hour: 22).date

    init() {}

    init(_ h: Habit) {
        name = h.name
        emoji = h.emoji
        color = h.color
        isMedication = h.isMedication
        dose = h.dose
        isShared = h.isShared

        let s = h.schedule
        timesPerDay = s.timesPerDay
        switch s.pattern {
        case .everyDay: pattern = .everyDay
        case .weekdays(let w): pattern = .weekdays; weekdays = w
        case .timesPerWeek(let n): pattern = .timesPerWeek; timesPerWeek = n
        case .everyNDays(let n): pattern = .everyNDays; everyN = n
        case .daysOfMonth(let d): pattern = .daysOfMonth; monthDays = d
        case .timesPerMonth(let n): pattern = .timesPerMonth; timesPerMonth = n
        }

        switch h.reminder {
        case .none: reminderKind = .none
        case .times(let t):
            reminderKind = .times
            times = t.sorted().map(\.date)
        case .interval(let minutes, let start, let end):
            reminderKind = .interval
            intervalHours = max(1, minutes / 60)
            intervalStart = start.date
            intervalEnd = end.date
        }
    }

    var reminder: ReminderRule {
        switch reminderKind {
        case .none: .none
        case .times: .times(times.map(TimeOfDay.init))
        case .interval: .interval(minutes: intervalHours * 60,
                                  start: TimeOfDay(intervalStart), end: TimeOfDay(intervalEnd))
        }
    }

    /// For a medicine on an interval, the daily target is the number of doses.
    var dosesFromReminder: Int? {
        guard isMedication, reminderKind != .none, pattern.isDayBased else { return nil }
        let n = reminder.slots.count
        return n > 0 ? n : nil
    }

    var schedule: Schedule {
        let perDay = dosesFromReminder ?? timesPerDay
        return switch pattern {
        case .everyDay: Schedule(pattern: .everyDay, timesPerDay: perDay)
        case .weekdays: Schedule(pattern: weekdays.isEmpty || weekdays.count == 7 ? .everyDay : .weekdays(weekdays),
                                 timesPerDay: perDay)
        case .timesPerWeek: Schedule(pattern: .timesPerWeek(timesPerWeek))
        case .everyNDays: Schedule(pattern: .everyNDays(everyN), timesPerDay: perDay)
        case .daysOfMonth: Schedule(pattern: .daysOfMonth(monthDays.isEmpty ? [1] : monthDays), timesPerDay: perDay)
        case .timesPerMonth: Schedule(pattern: .timesPerMonth(timesPerMonth))
        }
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool { !trimmedName.isEmpty }

    func apply(to h: Habit) {
        h.name = trimmedName
        h.emoji = emoji
        h.colorName = color.rawValue
        h.isMedication = isMedication
        h.dose = dose.trimmingCharacters(in: .whitespaces)
        h.isShared = isShared
        h.reminder = reminder
        h.changeSchedule(to: schedule)
    }

    func makeHabit(sortOrder: Double) -> Habit {
        let h = Habit(name: trimmedName, emoji: emoji, color: color, schedule: schedule,
                      reminder: reminder, isMedication: isMedication)
        h.dose = dose.trimmingCharacters(in: .whitespaces)
        h.isShared = isShared
        h.sortOrder = sortOrder
        return h
    }
}
