import SwiftUI
import SwiftData
import UIKit

@main
struct IlmekApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .modelContainer(store.container)
                .task { await GroupStore.shared.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                store.retryIfNeeded()
                store.refreshFromDisk()
                Reminders.shared.scheduleSoon()
                StatusPublisher.shared.publishSoon()
                Task { await GroupStore.shared.refresh() }
            case .background:
                Reminders.shared.submitRefresh()
                // Don't leave the last check-offs waiting in a 2-second timer while iOS suspends us.
                StatusPublisher.shared.publishInBackground()
            default: break
            }
        }
        .backgroundTask(.appRefresh(Reminders.refreshTaskID)) {
            await Reminders.shared.reschedule()
            await Reminders.shared.submitRefresh()
            // A new day started while the app was closed: friends shouldn't see yesterday as today.
            await StatusPublisher.shared.publish()
        }
    }
}

/// Owns the database for the app's lifetime.
///
/// Private iCloud database: habits, logs and stitches come back automatically after a reinstall
/// or on a new iPhone with the same Apple ID — no account needed.
///
/// iOS can start the app in the background before the phone has been unlocked after a restart;
/// the database file is still encrypted then and can't be opened. In that case this holds an
/// empty stand-in, starts none of the services (they would wipe the planned reminders and publish
/// "0 of 0" to friends), and switches to the real store as soon as it can be opened.
@MainActor
@Observable
final class AppStore {
    private(set) var container: ModelContainer
    private(set) var state: Store.State
    @ObservationIgnored private var servicesStarted = false
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?

    init() {
        #if DEBUG
        if DemoData.isOn {
            // Screenshot data in memory; no sync, reminders or publishing.
            container = DemoData.makeContainer()
            state = .localOnly
            servicesStarted = true
            DemoData.install(container)
            return
        }
        #endif
        Store.migrateLegacyStoreIfNeeded()
        (container, state) = Store.open(cloud: true)
        startServicesIfReal()

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil,
                       queue: .main) { [weak self] _ in
            Task { @MainActor in self?.retryIfNeeded() }
        }
        // Another process (the widget) or iCloud wrote to the store.
        nc.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshFromDiskSoon() }
        }
    }

    /// Opens the real store if we are still on the stand-in.
    func retryIfNeeded() {
        guard state == .memory else { return }
        let (opened, newState) = Store.open(cloud: true)
        guard newState != .memory else { return }
        container = opened
        state = newState
        startServicesIfReal()
    }

    private func startServicesIfReal() {
        guard state != .memory, !servicesStarted else { return }
        servicesStarted = true
        Reminders.shared.start(container: container)
        StatusPublisher.shared.start(container: container)
        StarterDedupe.start(container: container)
    }

    private func refreshFromDiskSoon() {
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            refreshFromDisk()
        }
    }

    /// Re-reads habits in the screen's context. Check-offs made in the widget are written by
    /// another process, and the open screens don't always notice those by themselves.
    func refreshFromDisk() {
        guard state != .memory else { return }
        var habits = FetchDescriptor<Habit>()
        habits.relationshipKeyPathsForPrefetching = [\.logs]
        _ = try? container.mainContext.fetch(habits)
    }
}
