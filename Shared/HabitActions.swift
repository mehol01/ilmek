import Foundation
import SwiftData
import IlmekKit

/// All mutations of habits go through here, so every change is saved right away
/// (CloudKit mirrors saved changes; unsaved ones would be lost if the app is killed).
@MainActor
extension Habit {
    func doneLogs(on day: DayKey) -> [HabitLog] {
        (logs ?? []).filter { $0.dayRaw == day.rawValue && $0.kind == .done }
    }

    func isSkipped(on day: DayKey) -> Bool {
        (logs ?? []).contains { $0.dayRaw == day.rawValue && $0.kind == .skip }
    }

    /// One more completion on `day`. Clears a skip on that day.
    func check(on day: DayKey, in context: ModelContext) {
        removeSkips(on: day, in: context)
        context.insert(HabitLog(habit: self, day: day))
        context.saveQuietly()
    }

    /// Removes the most recent completion on `day`.
    func undoOne(on day: DayKey, in context: ModelContext) {
        guard let last = doneLogs(on: day).max(by: { $0.timestamp < $1.timestamp }) else { return }
        context.delete(last)
        context.saveQuietly()
    }

    func clear(on day: DayKey, in context: ModelContext) {
        doneLogs(on: day).forEach(context.delete)
        removeSkips(on: day, in: context)
        context.saveQuietly()
    }

    func toggleSkip(on day: DayKey, in context: ModelContext) {
        if isSkipped(on: day) {
            removeSkips(on: day, in: context)
        } else {
            doneLogs(on: day).forEach(context.delete)
            context.insert(HabitLog(habit: self, day: day, kind: .skip))
        }
        context.saveQuietly()
    }

    private func removeSkips(on day: DayKey, in context: ModelContext) {
        (logs ?? []).filter { $0.dayRaw == day.rawValue && $0.kind == .skip }.forEach(context.delete)
    }

    /// Pauses the habit for a run of days: each becomes a skip (neutral for streaks, no reminders).
    /// Days already done keep their check-ins.
    func pause(from: DayKey, through: DayKey, in context: ModelContext, save: Bool = true) {
        let logs = self.logs ?? []
        for day in Pause.days(from: from, through: through)
        where !logs.contains(where: { $0.dayRaw == day.rawValue }) {
            context.insert(HabitLog(habit: self, day: day, kind: .skip))
        }
        if save { context.saveQuietly() }
    }

    /// Ends a pause: removes skips from `today` on.
    func resume(from today: DayKey, in context: ModelContext, save: Bool = true) {
        (logs ?? []).filter { $0.kind == .skip && $0.dayRaw >= today.rawValue }.forEach(context.delete)
        if save { context.saveQuietly() }
    }

    /// Last day of an ongoing pause, if any.
    func pausedThrough(today: DayKey) -> DayKey? {
        Pause.pausedThrough(history.skipped, today: today)
    }

    /// Applies a new schedule without rewriting the past: the streak so far is carried over and
    /// the new schedule takes effect today.
    func changeSchedule(to new: Schedule, today: DayKey = .today()) {
        guard new != schedule else { return }
        if startDay < today {
            let r = StreakEngine.evaluate(history, today: today.adding(days: -1),
                                          firstWeekday: Calendar.current.firstWeekday)
            carryStreak = r.current
            carryBest = r.best
            pastSchedules.append(ScheduleSegment(from: startDay, schedule: schedule))
            startDayRaw = today.rawValue
        }
        schedule = new
    }
}

extension ModelContext {
    func saveQuietly() {
        do { try save() } catch { assertionFailure("Save failed: \(error)") }
    }
}
