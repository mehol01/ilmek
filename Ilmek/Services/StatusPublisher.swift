import Foundation
import SwiftData
import UIKit
import IlmekKit

/// Builds my daily snapshot from local data and keeps the copy my friends see up to date.
///
/// "Up to date" is judged against what is actually on the server (the group cache, refreshed
/// from CloudKit), not against a private note of what was sent last. So whatever went wrong
/// before (a failed or overtaken upload, a reinstall, another device) the next trigger repairs it.
@MainActor
final class StatusPublisher {
    static let shared = StatusPublisher()

    private var container: ModelContainer?
    private var pending: Task<Void, Never>?
    /// Uploads run one after another, each with a fresh snapshot, so an older one can never
    /// land on top of a newer one.
    private var chain: Task<Void, Never>?
    private var lastCompleteDay = UserDefaults.standard.integer(forKey: "status.lastCompleteDay")

    func start(container: ModelContainer) {
        self.container = container
        let nc = NotificationCenter.default
        let soon: @Sendable (Notification) -> Void = { _ in
            Task { @MainActor in StatusPublisher.shared.publishSoon() }
        }
        nc.addObserver(forName: ModelContext.didSave, object: nil, queue: .main, using: soon)
        // Also the widget's check-offs and changes arriving from iCloud, which don't post didSave here.
        nc.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main, using: soon)
        // New day: friends must not see yesterday's numbers as today's.
        nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main, using: soon)
    }

    /// Coalesces a burst of changes into one upload.
    func publishSoon() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await publish()
        }
    }

    /// Uploads now and keeps the app alive for it. For moments when the app is about to be
    /// suspended: going to the background, or a check-off from a notification.
    func publishInBackground() {
        pending?.cancel()
        let keepAlive = BackgroundTime(name: "publish-status")
        Task {
            await publish()
            keepAlive.end()
        }
    }

    func publish(force: Bool = false) async {
        let previous = chain
        let task = Task { @MainActor in
            await previous?.value
            await self.publishNow(force: force)
        }
        chain = task
        await task.value
    }

    private func publishNow(force: Bool) async {
        let store = GroupStore.shared
        guard let container else { return }
        await store.ensureAccount()
        guard store.availability == .available, let me = store.myID,
              !store.groups.isEmpty || force else { return }
        // After a reinstall the nickname is gone from this phone but still on the server.
        if !Profile.isComplete { await store.restoreProfileIfNeeded() }
        guard Profile.isComplete else { return }

        let status = Self.makeStatus(context: ModelContext(container), userID: me)
        let completedToday = status.due > 0 && status.done >= status.due && lastCompleteDay != status.day
        let upToDate = store.status(of: me).map { $0.hasSameContent(as: status) } ?? false
        guard force || !upToDate || completedToday else { return }

        let keepAlive = BackgroundTime(name: "publish-status")
        defer { keepAlive.end() }
        do {
            try await store.publish(status, completedToday: completedToday && Profile.notifyFriends)
            if completedToday {
                lastCompleteDay = status.day
                UserDefaults.standard.set(status.day, forKey: "status.lastCompleteDay")
            }
        } catch {
            // Nothing is marked as sent, so the next save, foreground or refresh tries again.
        }
    }

    static func makeStatus(context: ModelContext, userID: String) -> FriendStatus {
        let cal = Calendar.current
        let today = DayKey.today()
        // Friends only ever learn about habits marked "share with friends". A private habit (or
        // medicine) is left out of everything sent: not its name, and not the totals, the
        // perfect-day streak or the daily history either, so even its existence stays private.
        let all = ((try? context.fetch(FetchDescriptor<Habit>())) ?? []).filter(\.isShared)
        let active = all.filter { $0.archivedAt == nil }
        let timelines = all.map(\.timeline)
        let summary = StreakEngine.summary(timelines, on: today, firstWeekday: cal.firstWeekday)

        let shared: [SharedHabit] = active
            .filter { $0.schedule.isDue(on: today, start: $0.startDay) }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { h in
                let r = StreakEngine.evaluate(h.history, today: today, firstWeekday: cal.firstWeekday)
                let unit = switch r.unit { case .day: "day"; case .week: "week"; case .month: "month" }
                return SharedHabit(name: h.name, emoji: h.emoji, color: h.colorName,
                                   progress: r.progress, target: r.target, streak: r.current, unit: unit)
            }

        var scarf: Data?
        // Daily progress for the friend heatmap; yarn colours only while the scarf is shared
        // (ScarfPayload.hiddenColor otherwise).
        if Profile.shareHistory {
            let showColors = Profile.knitEnabled && Profile.shareScarf
            let stitches = (try? context.fetch(FetchDescriptor<Stitch>(sortBy: [SortDescriptor(\.dayRaw)]))) ?? []
            let model = ScarfModel(habits: all, stitches: stitches, today: today, firstWeekday: cal.firstWeekday)
            if model.hasStarted {
                // Last ~3 years at most (~2 KB).
                let start = max(model.started, today.adding(days: -1095))
                var days: [(UInt8, UInt8)] = []
                var d = start
                while d <= today {
                    let idx = showColors ? UInt8(YarnColor.allCases.firstIndex(of: model.color(on: d)) ?? 0)
                                         : ScarfPayload.hiddenColor
                    days.append((idx, UInt8((model.fraction(on: d) * 255).rounded())))
                    d = d.adding(days: 1)
                }
                scarf = ScarfPayload(start: start, days: days.map { (color: $0.0, fraction: $0.1) }).data
            }
        }

        return FriendStatus(userID: userID, nickname: Profile.nickname, avatar: Profile.avatar,
                            day: today.rawValue, done: summary.done, due: summary.due,
                            perfectStreak: StreakEngine.perfectDayStreak(timelines, today: today,
                                                                         firstWeekday: cal.firstWeekday),
                            habits: shared, scarf: scarf, updatedAt: .now).sanitized()
    }
}

/// Background execution time that always gets handed back: if iOS says time is up before the
/// work finishes, the task is ended instead of letting the system kill the app.
@MainActor
final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

extension FriendStatus {
    /// Equal apart from the upload time.
    func hasSameContent(as other: FriendStatus) -> Bool {
        var a = self
        a.updatedAt = other.updatedAt
        return a == other
    }
}
