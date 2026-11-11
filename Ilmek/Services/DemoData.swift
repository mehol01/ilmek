#if DEBUG
import Foundation
import SwiftData
import IlmekKit

/// Sample data for App Store screenshots. Debug builds only, and only when launched with the
/// `-demo` argument (`./deploy.sh --demo`). Everything lives in memory: nothing is written to
/// iCloud, the real store, or the public group database, and no reminders are planned.
@MainActor
enum DemoData {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    static let myID = "demo-me"

    /// Screenshots in English get English sample names (`DEMO_LANG=en ./deploy.sh --demo`).
    private static let english = Locale.preferredLanguages.first?.hasPrefix("en") ?? false
    private static func t(_ tr: String, _ en: String) -> String { english ? en : tr }

    static func makeContainer() -> ModelContainer {
        let schema = Schema(IlmekSchema.models)
        // .none matters: the default (.automatic) would mirror the demo to the iCloud container.
        let config = ModelConfiguration("IlmekDemo", schema: schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        let container = try! ModelContainer(for: schema, configurations: config)
        seed(container.mainContext)
        return container
    }

    /// Profile, flags and the fake friend group. Call once the container exists.
    static func install(_ container: ModelContainer) {
        let d = UserDefaults.standard
        d.set(true, forKey: "onboarded")
        d.set("Ada", forKey: Profile.nicknameKey)
        d.set("🌿", forKey: Profile.avatarKey)
        d.set(true, forKey: Profile.knitEnabledKey)
        d.set(true, forKey: Profile.shareScarfKey)

        let me = StatusPublisher.makeStatus(context: container.mainContext, userID: myID)
        var cache = GroupCache()
        cache.myID = myID
        let group = GroupInfo(code: "K7QF29XM", name: t("Kampüs Ekibi", "Campus Crew"), ownerID: myID,
                              memberLimit: 0, banned: [])
        let friends = Self.friends()
        cache.groups = [group]
        cache.members[group.code] = [myID] + friends.map(\.userID)
        cache.statuses[myID] = me
        for f in friends { cache.statuses[f.userID] = f }
        cache.refreshedAt = .now
        GroupStore.shared.useDemo(cache)
    }

    // MARK: Habits

    private struct Plan {
        var name: String, emoji: String, color: YarnColor
        var schedule: Schedule = .daily
        var reminder: ReminderRule = .none
        var medication = false
        var shared = true
        var rate: Double            // chance a past day is done
        var today: Int              // completions today
    }

    private static func seed(_ context: ModelContext) {
        let today = DayKey.today()
        let start = today.adding(days: -150)
        var rng = SeededRandom(seed: 7)
        let plans = [
            Plan(name: t("Su iç", "Drink water"), emoji: "💧", color: .teal,
                 schedule: Schedule(pattern: .everyDay, timesPerDay: 8), rate: 0.9, today: 5),
            Plan(name: t("Kitap oku", "Read"), emoji: "📖", color: .indigo,
                 reminder: .times([TimeOfDay(hour: 21, minute: 30)]), rate: 0.86, today: 0),
            Plan(name: t("Meditasyon", "Meditate"), emoji: "🧘", color: .sage,
                 reminder: .times([TimeOfDay(hour: 7, minute: 30)]), rate: 0.82, today: 1),
            Plan(name: t("Koşu", "Run"), emoji: "🏃", color: .terracotta,
                 schedule: Schedule(pattern: .weekdays([2, 4, 6])), rate: 0.8, today: 1),
            Plan(name: t("D vitamini", "Vitamin D"), emoji: "💊", color: .saffron,
                 reminder: .times([TimeOfDay(hour: 9, minute: 0)]), medication: true, shared: false,
                 rate: 0.95, today: 1),
            Plan(name: t("İngilizce kelime", "Spanish words"), emoji: t("🇬🇧", "🇪🇸"), color: .plum,
                 reminder: .times([TimeOfDay(hour: 13, minute: 0)]), rate: 0.75, today: 0),
        ]

        for (i, p) in plans.enumerated() {
            let h = Habit(name: p.name, emoji: p.emoji, color: p.color, schedule: p.schedule,
                          reminder: p.reminder, isMedication: p.medication, startDay: start)
            h.isShared = p.shared
            h.sortOrder = Double(i)
            h.createdAt = start.startDate(in: .current)
            context.insert(h)

            var day = start
            while day < today {
                let recent = day.days(to: today) <= 24          // an unbroken recent streak
                if p.schedule.isDue(on: day, start: start), recent || rng.next() < p.rate {
                    let target = p.schedule.timesPerDay
                    let n = recent || rng.next() < 0.7 ? target : max(1, target - Int(rng.next() * 3) - 1)
                    for _ in 0..<n { context.insert(HabitLog(habit: h, day: day)) }
                }
                day = day.adding(days: 1)
            }
            for _ in 0..<p.today { context.insert(HabitLog(habit: h, day: today)) }
        }

        // Scarf: a new yarn every week or so.
        let yarns: [YarnColor] = [.teal, .saffron, .sage, .rose, .indigo, .terracotta, .olive, .plum]
        var day = start
        while day <= today {
            context.insert(Stitch(day: day, color: yarns[(start.days(to: day) / 8) % yarns.count]))
            day = day.adding(days: 1)
        }
        try? context.save()
    }

    // MARK: Friends

    private static func friends() -> [FriendStatus] {
        let today = DayKey.today()
        var rng = SeededRandom(seed: 42)
        func scarf(rate: Double, offset: Int, streak: Int) -> Data {
            let start = today.adding(days: -150)
            let days = (0...150).map { i -> (color: UInt8, fraction: UInt8) in
                let f = i > 150 - streak || rng.next() < rate ? 1.0 : rng.next() * 0.7
                return (UInt8(((i + offset) / 9) % YarnColor.allCases.count), UInt8(f * 255))
            }
            return ScarfPayload(start: start, days: days).data
        }
        func habit(_ name: String, _ emoji: String, _ color: YarnColor, _ progress: Int, _ target: Int,
                   _ streak: Int, unit: String = "day") -> SharedHabit {
            SharedHabit(name: name, emoji: emoji,
                        color: color.rawValue, progress: progress, target: target, streak: streak, unit: unit)
        }
        return [
            FriendStatus(userID: "demo-ece", nickname: t("Ece", "Emma"), avatar: "🌸", day: today.rawValue,
                         done: 4, due: 4, perfectStreak: 31,
                         habits: [habit(t("Yoga", "Yoga"), "🧘", .rose, 1, 1, 31),
                                  habit(t("Su iç", "Drink water"), "💧", .teal, 8, 8, 45),
                                  habit(t("Günlük yaz", "Journal"), "✍️", .plum, 1, 1, 12),
                                  habit(t("Erken kalk", "Wake up early"), "⏰", .saffron, 1, 1, 19)],
                         scarf: scarf(rate: 0.85, offset: 3, streak: 31), updatedAt: .now),
            FriendStatus(userID: "demo-can", nickname: t("Can", "Leo"), avatar: "⚡️", day: today.rawValue,
                         done: 2, due: 3, perfectStreak: 8,
                         habits: [habit(t("Spor salonu", "Gym"), "🏋️", .terracotta, 2, 4, 6, unit: "week"),
                                  habit(t("Kitap oku", "Read"), "📖", .indigo, 1, 1, 14),
                                  habit(t("Şekersiz gün", "No sugar"), "🍏", .olive, 0, 1, 8)],
                         scarf: scarf(rate: 0.7, offset: 11, streak: 8), updatedAt: .now),
            FriendStatus(userID: "demo-zeynep", nickname: t("Zeynep", "Zoe"), avatar: "🐢", day: today.rawValue,
                         done: 1, due: 3, perfectStreak: 3,
                         habits: [habit(t("Yürüyüş", "Walk"), "🚶", .sage, 1, 1, 22),
                                  habit(t("Gitar", "Guitar"), "🎸", .charcoal, 0, 1, 3),
                                  habit(t("Su iç", "Drink water"), "💧", .teal, 4, 6, 9)],
                         scarf: scarf(rate: 0.6, offset: 20, streak: 3), updatedAt: .now),
            FriendStatus(userID: "demo-mert", nickname: t("Mert", "Max"), avatar: "🎧", day: today.rawValue,
                         done: 3, due: 3, perfectStreak: 15,
                         habits: [habit(t("Meditasyon", "Meditate"), "🧘", .sage, 1, 1, 15),
                                  habit(t("Kod çalış", "Code practice"), "💻", .indigo, 1, 1, 27),
                                  habit(t("Koşu", "Run"), "🏃", .terracotta, 2, 3, 4, unit: "week")],
                         scarf: scarf(rate: 0.78, offset: 30, streak: 15), updatedAt: .now),
        ]
    }
}

/// Small deterministic generator, so every demo launch looks the same.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}
#endif
