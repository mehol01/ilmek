import Foundation
import SwiftData
import UserNotifications
import BackgroundTasks
import WidgetKit
import IlmekKit

/// Keeps pending local notifications in sync with habits.
///
/// iOS allows 64 pending requests, so we never use repeating triggers: `ReminderPlanner` picks
/// the nearest ~60 fire dates and we replace the whole set. Re-planned on launch, foreground,
/// every save, iCloud changes from other devices and a daily background refresh.
@MainActor
final class Reminders: NSObject {
    static let shared = Reminders()

    static let category = "habit"
    static let actionDone = "done"
    static let actionSnooze = "snooze"
    static let refreshTaskID = "com.mehol01.Ilmek.refresh"
    private static let prefix = "ilmek|"

    private let center = UNUserNotificationCenter.current()
    private var container: ModelContainer?
    private var pending: Task<Void, Never>?
    /// Bumped by every re-plan; an older run that is still awaiting the system gives up.
    private var planGeneration = 0

    /// Everything a notification needs, copied out of the database up front. SwiftData models
    /// must not be read after an `await`: if a log was deleted meanwhile (an undo, the widget,
    /// sync), touching it is a fatal error.
    private struct HabitSnapshot {
        let id: String
        let title: String
        let body: String
        let isMedication: Bool
        let history: HabitHistory
        let rule: ReminderRule
    }

    func start(container: ModelContainer) {
        self.container = container
        center.delegate = self
        let done = UNNotificationAction(identifier: Self.actionDone, title: String(localized: "Tamamla"),
                                        options: [], icon: .init(systemImageName: "checkmark"))
        let snooze = UNNotificationAction(identifier: Self.actionSnooze, title: String(localized: "10 dk sonra"),
                                          options: [], icon: .init(systemImageName: "clock"))
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category,
                                                                 actions: [done, snooze], intentIdentifiers: [])])

        let nc = NotificationCenter.default
        nc.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            Task { @MainActor in Reminders.shared.scheduleSoon() }
        }
        nc.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { _ in
            Task { @MainActor in Reminders.shared.scheduleSoon() }
        }
        scheduleSoon()
    }

    // MARK: Permission

    /// Asks once, the first time a habit with a reminder is saved.
    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .denied:
            return false
        default:
            return true
        }
    }

    func isDenied() async -> Bool {
        await center.notificationSettings().authorizationStatus == .denied
    }

    // MARK: Planning

    /// Coalesces bursts of saves (sync can deliver dozens) into one re-plan.
    func scheduleSoon() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadAllTimelines()
            await reschedule()
        }
    }

    func reschedule() async {
        guard let container else { return }
        planGeneration += 1
        let generation = planGeneration
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
              generation == planGeneration else { return }

        // Synchronous from here to the snapshot: no await while models are in hand.
        let context = ModelContext(container)
        let habits = (try? context.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.archivedAt == nil }))) ?? []
        let snapshots = habits.map { h in
            HabitSnapshot(id: h.id.uuidString, title: "\(h.emoji) \(h.name)", body: body(for: h),
                          isMedication: h.isMedication, history: h.history, rule: h.reminder)
        }
        let byID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let inputs = snapshots.map { ReminderPlanner.Input(id: $0.id, history: $0.history, rule: $0.rule) }
        let plan = ReminderPlanner.plan(inputs, now: .now, calendar: .current)

        let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        guard generation == planGeneration else { return }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        // Tidy Notification Center: reminders for days already done (or habits gone) are stale,
        // and tapping "Done" on them would over-count.
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
            .filter { $0.hasPrefix(Self.prefix) }
        let stale = delivered.filter { id in
            let parts = id.dropFirst(Self.prefix.count).split(separator: "|")
            guard parts.count >= 2, let habit = byID[String(parts[0])],
                  let raw = Int(parts[1]), let day = DayKey(rawValue: raw) else { return true }
            return Self.isSatisfied(habit.history, on: day)
        }
        center.removeDeliveredNotifications(withIdentifiers: stale)

        for r in plan {
            // A newer plan started (another save): it replaces everything, stop adding to the old one.
            guard generation == planGeneration else { return }
            guard let habit = byID[r.habitID] else { continue }
            let content = UNMutableNotificationContent()
            content.title = habit.title
            content.body = habit.body
            content.sound = .default
            content.categoryIdentifier = Self.category
            content.threadIdentifier = r.habitID
            content.userInfo = ["habit": r.habitID, "day": r.day.rawValue]
            content.interruptionLevel = habit.isMedication ? .timeSensitive : .active

            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: r.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.prefix + r.identifier,
                                                        content: content, trigger: trigger))
        }
    }

    /// Nothing left to remind about for `day`.
    static func isSatisfied(_ h: HabitHistory, on day: DayKey) -> Bool {
        if h.skipped.contains(day) { return true }
        switch h.schedule.period {
        case .day: return h.count(on: day) >= h.schedule.timesPerDay
        case .week, .month:
            return StreakEngine.evaluate(h, today: day, firstWeekday: Calendar.current.firstWeekday).isCurrentUnitDone
        }
    }

    private func body(for habit: Habit) -> String {
        if habit.isMedication {
            return habit.dose.isEmpty ? String(localized: "İlaç zamanı") : String(localized: "İlaç zamanı · \(habit.dose)")
        }
        let streak = StreakEngine.evaluate(habit.history, today: .today(), firstWeekday: Calendar.current.firstWeekday).current
        guard streak > 1 else { return String(localized: "Bugünün ilmeğini atma zamanı") }
        return switch habit.schedule.period {
        case .day: String(localized: "🔥 \(streak) günlük serini koru")
        case .week: String(localized: "🔥 \(streak) haftalık serini koru")
        case .month: String(localized: "🔥 \(streak) aylık serini koru")
        }
    }

    // MARK: Background refresh

    /// Refills the window even if the app isn't opened for days.
    func submitRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        req.earliestBeginDate = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 3),
                                                          matchingPolicy: .nextTime)
        try? BGTaskScheduler.shared.submit(req)
    }

    // MARK: Actions

    fileprivate func handle(action: String, habitID id: String, dayRaw raw: Int,
                            title: String, body: String) async {
        guard let container, let day = DayKey(rawValue: raw) else { return }
        switch action {
        case Self.actionDone:
            // The app's main context, so an open screen sees the check right away.
            let context = container.mainContext
            let all = (try? context.fetch(FetchDescriptor<Habit>())) ?? []
            guard let habit = all.first(where: { $0.id.uuidString == id }) else { return }
            // An old notification for something already done must not add an extra check.
            if !Self.isSatisfied(habit.history, on: day) { habit.check(on: day, in: context) }
            // Friends should see it even though the app may be suspended again in a moment.
            StatusPublisher.shared.publishInBackground()
            await reschedule()
        case Self.actionSnooze:
            let copy = UNMutableNotificationContent()
            copy.title = title
            copy.body = body
            copy.sound = .default
            copy.categoryIdentifier = Self.category
            copy.threadIdentifier = id
            copy.userInfo = ["habit": id, "day": raw]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "snooze|\(UUID().uuidString)",
                                                        content: copy, trigger: trigger))
        default:
            break
        }
    }
}

extension Reminders: UNUserNotificationCenterDelegate {
    // The completion-handler forms on purpose. With the `async` forms Swift calls the system's
    // completion handler from a background thread, and UIKit requires the main thread there when
    // the app was woken in the background (a tap or an action from the lock screen): on some iOS
    // versions that is an immediate crash.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let id = content.userInfo["habit"] as? String
        let raw = content.userInfo["day"] as? Int
        let action = response.actionIdentifier, title = content.title, body = content.body
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            // Friend/group pushes carry no habit: nothing to do but open the app.
            if let id, let raw {
                await Reminders.shared.handle(action: action, habitID: id, dayRaw: raw, title: title, body: body)
            }
            done()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
