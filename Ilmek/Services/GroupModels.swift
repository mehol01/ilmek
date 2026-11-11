import Foundation
import IlmekKit

// Plain values cached on disk, so the Friends tab renders instantly — even offline.

struct GroupInfo: Codable, Hashable, Identifiable {
    var code: String
    var name: String
    var ownerID: String
    var memberLimit: Int          // 0 = unlimited
    var banned: [String]
    var id: String { code }

    var displayCode: String { GroupCode.display(code) }
}

struct SharedHabit: Codable, Hashable {
    var name: String
    var emoji: String
    var color: String
    var progress: Int
    var target: Int
    var streak: Int
    var unit: String               // "day" | "week" | "month"

    var isDone: Bool { progress >= target }
}

/// What a member publishes about themself. One record per user, shared by all their groups.
struct FriendStatus: Codable, Hashable {
    var userID: String
    var nickname: String
    var avatar: String
    var day: Int                   // DayKey.rawValue of their local day
    var done: Int
    var due: Int
    var perfectStreak: Int
    var habits: [SharedHabit]
    var scarf: Data?               // ScarfPayload, only if they share it
    var updatedAt: Date

    var dayKey: DayKey? { DayKey(rawValue: day) }
    var scarfPayload: ScarfPayload? { scarf.flatMap(ScarfPayload.init(data:)) }

    /// Brings every field into a sane range. Statuses are written by other people's phones into
    /// a public database, so a buggy or hostile client must not be able to crash or freeze this
    /// app with absurd values. Applied to what we send as well, so both sides stay equal.
    func sanitized() -> FriendStatus {
        func count(_ n: Int) -> Int { min(max(n, 0), 100_000) }
        var s = self
        s.nickname = WordFilter.clean(String(nickname.prefix(40)))
        s.avatar = String(avatar.prefix(4))
        s.done = count(done)
        s.due = count(due)
        s.perfectStreak = count(perfectStreak)
        s.habits = habits.prefix(100).map { h in
            SharedHabit(name: WordFilter.clean(String(h.name.prefix(80))), emoji: String(h.emoji.prefix(4)),
                        color: String(h.color.prefix(24)), progress: count(h.progress),
                        target: count(h.target), streak: count(h.streak), unit: String(h.unit.prefix(8)))
        }
        if let scarf, scarf.count > ScarfPayload.maxBytes { s.scarf = nil }
        return s
    }
}

struct GroupCache: Codable {
    var myID: String?
    var groups: [GroupInfo] = []
    var members: [String: [String]] = [:]         // code → userIDs
    var statuses: [String: FriendStatus] = [:]    // userID → status
    var refreshedAt: Date?

    private static var url: URL {
        URL.applicationSupportDirectory.appending(path: "groups-cache.json")
    }

    static func load() -> GroupCache {
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(GroupCache.self, from: data) else { return GroupCache() }
        return c
    }

    func save() {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
}

/// Local profile. Stored in UserDefaults and published inside the status record.
enum Profile {
    static let nicknameKey = "profile.nickname"
    static let avatarKey = "profile.avatar"
    static let shareScarfKey = "profile.shareScarf"
    static let notifyFriendsKey = "profile.notifyFriends"
    /// Opt-in scarf mode. Off: the second tab is plain stats and scarves are hidden everywhere.
    static let knitEnabledKey = "knit.enabled"
    /// Daily progress history (the friend heatmap). Independent of knit mode.
    static let shareHistoryKey = "profile.shareHistory"
    /// People I blocked: userID → nickname at the time. Only on this phone.
    static let blockedKey = "profile.blocked"

    static var nickname: String { UserDefaults.standard.string(forKey: nicknameKey) ?? "" }
    static var avatar: String { UserDefaults.standard.string(forKey: avatarKey) ?? "🙂" }
    static var shareScarf: Bool { UserDefaults.standard.object(forKey: shareScarfKey) as? Bool ?? true }
    static var notifyFriends: Bool { UserDefaults.standard.object(forKey: notifyFriendsKey) as? Bool ?? true }
    static var knitEnabled: Bool { UserDefaults.standard.bool(forKey: knitEnabledKey) }
    static var shareHistory: Bool { UserDefaults.standard.object(forKey: shareHistoryKey) as? Bool ?? true }
    static var isComplete: Bool { !nickname.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Brings back the name and avatar this user published before. Deleting the app wipes them
    /// from the phone, and without a nickname nothing is published to friends. Never overwrites
    /// what is already set here.
    static func restoreIfMissing(nickname: String?, avatar: String?) {
        let d = UserDefaults.standard
        guard !isComplete, let nickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines),
              !nickname.isEmpty else { return }
        d.set(String(nickname.prefix(24)), forKey: nicknameKey)
        if d.object(forKey: avatarKey) == nil, let avatar, !avatar.isEmpty { d.set(avatar, forKey: avatarKey) }
    }
}

enum GroupError: LocalizedError {
    case noAccount, codeInvalid, codeNotFound, banned, full, network, notOwner, other(String)

    var errorDescription: String? {
        switch self {
        case .noAccount: String(localized: "Gruplar için iPhone'da iCloud'a giriş yapmış olmalısın.")
        case .codeInvalid: String(localized: "Kod 8 karakter olmalı, örn. K7QF-29XM.")
        case .codeNotFound: String(localized: "Bu kodla bir grup bulunamadı.")
        case .banned: String(localized: "Bu gruba katılamazsın.")
        case .full: String(localized: "Grup dolu.")
        case .network: String(localized: "İnternet bağlantısı yok. Biraz sonra tekrar dene.")
        case .notOwner: String(localized: "Bunu sadece grubu kuran yapabilir.")
        case .other(let m): m
        }
    }
}
