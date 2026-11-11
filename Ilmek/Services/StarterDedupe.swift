import Foundation
import SwiftData

/// After a reinstall, iCloud can take a while to bring habits back. If the user picked starter
/// habits in onboarding meanwhile, an older habit with the same name may arrive later. The
/// untouched starter is then a duplicate and is removed quietly.
@MainActor
enum StarterDedupe {
    private static let key = "onboarding.starters"   // habit UUID → time created
    private static let window: TimeInterval = 14 * 86_400
    private static var pending: Task<Void, Never>?

    static func remember(_ habits: [Habit]) {
        var map = stored
        for h in habits { map[h.id.uuidString] = Date.now.timeIntervalSince1970 }
        UserDefaults.standard.set(map, forKey: key)
    }

    static func start(container: ModelContainer) {
        guard !stored.isEmpty else { return }
        NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { _ in
            Task { @MainActor in runSoon(container) }
        }
        runSoon(container)
    }

    private static func runSoon(_ container: ModelContainer) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            // The main context: deleting through a second one can leave a screen holding a
            // habit whose data is gone.
            run(in: container.mainContext)
        }
    }

    static func run(in context: ModelContext) {
        var map = stored.filter { Date.now.timeIntervalSince1970 - $0.value < window }
        guard !map.isEmpty else { UserDefaults.standard.removeObject(forKey: key); return }
        let all = (try? context.fetch(FetchDescriptor<Habit>())) ?? []
        var changed = false
        for h in all where map[h.id.uuidString] != nil {
            let name = h.name.trimmingCharacters(in: .whitespaces).lowercased()
            let olderTwin = all.contains {
                $0.id != h.id && $0.createdAt < h.createdAt
                    && $0.name.trimmingCharacters(in: .whitespaces).lowercased() == name
            }
            guard olderTwin else { continue }
            map[h.id.uuidString] = nil
            if (h.logs ?? []).isEmpty {
                context.delete(h)
                changed = true
            }
        }
        if changed { context.saveQuietly() }
        UserDefaults.standard.set(map, forKey: key)
    }

    private static var stored: [String: Double] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }
}
