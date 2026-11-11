import Foundation
import SwiftData
import IlmekKit

/// Vacation = pausing many habits at once. It's just per-habit pauses, so it syncs and shows up
/// the same on every device.
@MainActor
enum Vacation {
    static func start(through end: DayKey, includeMedications: Bool, habits: [Habit], in context: ModelContext) {
        let today = DayKey.today()
        for h in habits where h.archivedAt == nil && (includeMedications || !h.isMedication) {
            h.pause(from: today, through: end, in: context, save: false)
        }
        context.saveQuietly()
    }

    static func end(habits: [Habit], in context: ModelContext) {
        let today = DayKey.today()
        for h in paused(habits, today: today) { h.resume(from: today, in: context, save: false) }
        context.saveQuietly()
    }

    static func paused(_ habits: [Habit], today: DayKey) -> [Habit] {
        habits.filter { $0.archivedAt == nil && $0.pausedThrough(today: today) != nil }
    }

    /// The furthest end among paused habits.
    static func until(_ habits: [Habit], today: DayKey) -> DayKey? {
        habits.filter { $0.archivedAt == nil }.compactMap { $0.pausedThrough(today: today) }.max()
    }
}
