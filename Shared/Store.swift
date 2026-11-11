import Foundation
import SwiftData
import os

/// One store for the app and the widget, in the App Group container.
///
/// The app mirrors it to the iCloud private database. The widget opens the same file without
/// CloudKit; its writes land in persistent history and the app exports them on next launch —
/// Apple's recommended split, so two processes never run sync at once.
enum Store {
    static let appGroup = "group.com.mehol01.Ilmek"
    static let cloudContainer = "iCloud.com.mehol01.Ilmek"
    static let fileName = "Ilmek.store"

    static var directory: URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? URL.applicationSupportDirectory
        let dir = base.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var url: URL { directory.appending(path: fileName) }

    /// Moves a store created before the App Group existed (first dev builds) into the group.
    static func migrateLegacyStoreIfNeeded() {
        let fm = FileManager.default
        let old = URL.applicationSupportDirectory
        guard old.standardizedFileURL != directory.standardizedFileURL,
              fm.fileExists(atPath: old.appending(path: fileName).path),
              !fm.fileExists(atPath: url.path) else { return }
        let items = (try? fm.contentsOfDirectory(atPath: old.path)) ?? []
        for name in items where name.hasPrefix("Ilmek.store") || name.hasPrefix(".Ilmek_SUPPORT")
            || name.hasPrefix("Ilmek_ckAssets") {
            try? fm.moveItem(at: old.appending(path: name), to: directory.appending(path: name))
        }
    }

    enum State: Sendable {
        /// The real store, mirrored to iCloud.
        case cloud
        /// The real store, but iCloud mirroring could not be set up (or wasn't asked for).
        case localOnly
        /// The real store could not be opened (typically: the phone has not been unlocked since
        /// it restarted, so its files are still encrypted). This is an empty stand-in: callers
        /// must not treat it as the user's data — no reminders re-planned from it, nothing
        /// published from it, nothing the user enters saved into it.
        case memory
    }

    /// iCloud → local-only → empty stand-in, so the process always starts. Check `State`.
    static func open(cloud: Bool) -> (ModelContainer, State) {
        let schema = Schema(IlmekSchema.models)
        if cloud {
            let c = ModelConfiguration("Ilmek", schema: schema, url: url,
                                       cloudKitDatabase: .private(cloudContainer))
            do { return (try ModelContainer(for: schema, configurations: c), .cloud) }
            catch { log.error("Opening the iCloud store failed: \(String(describing: error), privacy: .public)") }
        }
        let local = ModelConfiguration("Ilmek", schema: schema, url: url, cloudKitDatabase: .none)
        do { return (try ModelContainer(for: schema, configurations: local), .localOnly) }
        catch { log.error("Opening the local store failed: \(String(describing: error), privacy: .public)") }
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // An in-memory store has nothing to read from disk; if even this fails nothing can run.
        return (try! ModelContainer(for: schema, configurations: memory), .memory)
    }

    private static let log = Logger(subsystem: "com.mehol01.Ilmek", category: "store")
}
