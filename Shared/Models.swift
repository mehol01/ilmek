import Foundation
import SwiftData
import IlmekKit

// CloudKit-backed SwiftData rules: every property has a default or is optional,
// no @Attribute(.unique), every relationship is optional. Breaking these makes the
// container fail to load, so keep it that way when adding fields.

@Model
final class Habit {
    var id: UUID = UUID()
    var name: String = ""
    var emoji: String = "✨"
    var colorName: String = YarnColor.terracotta.rawValue
    var scheduleData: Data?
    var reminderData: Data?
    var startDayRaw: Int = 0
    var sortOrder: Double = 0
    var isMedication: Bool = false
    var dose: String = ""
    /// Shown to friends in groups. Medicines default to private.
    var isShared: Bool = true
    var archivedAt: Date?
    var createdAt: Date = Date()
    /// See `HabitHistory.carryOver`: set when the schedule changes.
    var carryStreak: Int = 0
    var carryBest: Int = 0
    /// Earlier schedules (`[ScheduleSegment]` JSON), so past days keep their original rules.
    var pastSchedulesData: Data?

    @Relationship(deleteRule: .cascade, inverse: \HabitLog.habit)
    var logs: [HabitLog]? = []

    init(name: String, emoji: String = "✨", color: YarnColor = .terracotta,
         schedule: Schedule = .daily, reminder: ReminderRule = .none,
         isMedication: Bool = false, startDay: DayKey = .today()) {
        self.name = name
        self.emoji = emoji
        self.colorName = color.rawValue
        self.isMedication = isMedication
        self.isShared = !isMedication
        self.startDayRaw = startDay.rawValue
        self.schedule = schedule
        self.reminder = reminder
    }

    var schedule: Schedule {
        get { scheduleData.flatMap { try? JSONDecoder().decode(Schedule.self, from: $0) } ?? .daily }
        set { scheduleData = try? JSONEncoder().encode(newValue) }
    }

    var reminder: ReminderRule {
        get { reminderData.flatMap { try? JSONDecoder().decode(ReminderRule.self, from: $0) } ?? .none }
        set { reminderData = try? JSONEncoder().encode(newValue) }
    }

    var pastSchedules: [ScheduleSegment] {
        get { pastSchedulesData.flatMap { try? JSONDecoder().decode([ScheduleSegment].self, from: $0) } ?? [] }
        set { pastSchedulesData = try? JSONEncoder().encode(newValue) }
    }

    var timeline: HabitTimeline {
        HabitTimeline(current: history, past: pastSchedules,
                      endDay: archivedAt.map { DayKey($0, calendar: .current) })
    }

    var startDay: DayKey { DayKey(rawValue: startDayRaw) ?? DayKey(createdAt, calendar: .current) }

    var color: YarnColor { YarnColor(rawValue: colorName) ?? .terracotta }

    /// Engine input. Logs are de-duplicated by id, so a record that sync delivered twice
    /// can't double-count.
    var history: HabitHistory {
        var counts: [DayKey: Int] = [:]
        var skipped: Set<DayKey> = []
        var seen: Set<UUID> = []
        for log in logs ?? [] where seen.insert(log.id).inserted {
            guard let day = DayKey(rawValue: log.dayRaw) else { continue }
            switch log.kind {
            case .done: counts[day, default: 0] += 1
            case .skip: skipped.insert(day)
            }
        }
        return HabitHistory(schedule: schedule, startDay: startDay, counts: counts, skipped: skipped,
                            carryOver: carryStreak, carryBest: carryBest)
    }
}

@Model
final class HabitLog {
    enum Kind: String { case done, skip }

    var id: UUID = UUID()
    /// Local day at the moment of logging (`DayKey.rawValue`). Never recomputed.
    var dayRaw: Int = 0
    var timestamp: Date = Date()
    var kindRaw: String = Kind.done.rawValue
    var habit: Habit?

    init(habit: Habit, day: DayKey, kind: Kind = .done) {
        self.habit = habit
        self.dayRaw = day.rawValue
        self.kindRaw = kind.rawValue
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .done }
}

/// One stitch of the knitting: the yarn colour picked for a day.
@Model
final class Stitch {
    var dayRaw: Int = 0
    var colorName: String = YarnColor.terracotta.rawValue
    var updatedAt: Date = Date()

    init(day: DayKey, color: YarnColor) {
        self.dayRaw = day.rawValue
        self.colorName = color.rawValue
    }
}

enum IlmekSchema {
    static let models: [any PersistentModel.Type] = [Habit.self, HabitLog.self, Stitch.self]
}
