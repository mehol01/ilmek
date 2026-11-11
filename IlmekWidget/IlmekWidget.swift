import WidgetKit
import SwiftUI
import SwiftData
import AppIntents
import UserNotifications
import IlmekKit

@main
struct IlmekWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
    }
}

// MARK: - Data

@MainActor
enum WidgetStore {
    private static var opened: ModelContainer?

    /// No CloudKit in the extension; the app syncs what the widget writes.
    /// `nil` while the store can't be opened (phone not unlocked since it restarted); the empty
    /// stand-in is never kept, so the next attempt tries the real file again.
    static var container: ModelContainer? {
        if let opened { return opened }
        let (container, state) = Store.open(cloud: false)
        guard state != .memory else { return nil }
        opened = container
        return container
    }
}

struct WidgetHabit: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let color: YarnColor
    let progress: Int
    let target: Int
    let isPeriodic: Bool
    var isDone: Bool { progress >= target }
}

struct TodayEntry: TimelineEntry {
    let date: Date
    let done: Int
    let due: Int
    let perfectStreak: Int
    let habits: [WidgetHabit]
    /// The store couldn't be read: show a hint instead of a misleading "0 of 0".
    var isLocked = false

    static let placeholder = TodayEntry(date: .now, done: 2, due: 4, perfectStreak: 6, habits: [
        WidgetHabit(id: "1", name: "Kitap oku", emoji: "📚", color: .indigo, progress: 1, target: 1, isPeriodic: false),
        WidgetHabit(id: "2", name: "Su iç", emoji: "💧", color: .teal, progress: 5, target: 8, isPeriodic: false),
        WidgetHabit(id: "3", name: "Yürüyüş", emoji: "🚶", color: .olive, progress: 0, target: 1, isPeriodic: false),
        WidgetHabit(id: "4", name: "Vitamin", emoji: "💊", color: .rose, progress: 1, target: 1, isPeriodic: false),
    ])
}

@MainActor
func makeEntry(at date: Date = .now) -> TodayEntry {
    let cal = Calendar.current
    let today = DayKey(date, calendar: cal)
    guard let container = WidgetStore.container else {
        return TodayEntry(date: date, done: 0, due: 0, perfectStreak: 0, habits: [], isLocked: true)
    }
    let context = ModelContext(container)
    let all = (try? context.fetch(FetchDescriptor<Habit>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
    let active = all.filter { $0.archivedAt == nil }
    let timelines = all.map(\.timeline)
    let summary = StreakEngine.summary(timelines, on: today, firstWeekday: cal.firstWeekday)

    let habits: [WidgetHabit] = active.compactMap { h in
        let hist = h.history
        guard hist.schedule.isDue(on: today, start: hist.startDay), !hist.skipped.contains(today) else { return nil }
        let r = StreakEngine.evaluate(hist, today: today, firstWeekday: cal.firstWeekday)
        // Weekly/monthly already done this week and not today → not part of today.
        if r.unit != .day && r.isCurrentUnitDone && hist.count(on: today) == 0 { return nil }
        return WidgetHabit(id: h.id.uuidString, name: h.name, emoji: h.emoji, color: h.color,
                           progress: r.unit == .day ? hist.count(on: today) : r.progress,
                           target: r.target, isPeriodic: r.unit != .day)
    }
    .sorted { !$0.isDone && $1.isDone }

    return TodayEntry(date: date, done: summary.done, due: summary.due,
                      perfectStreak: StreakEngine.perfectDayStreak(timelines, today: today,
                                                                   firstWeekday: cal.firstWeekday),
                      habits: habits)
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        if context.isPreview { completion(.placeholder); return }
        Task { @MainActor in completion(makeEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        Task { @MainActor in
            let now = Date.now
            let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))
            // A fresh entry right after midnight so yesterday's ticks never show as today's.
            let first = makeEntry(at: now)
            guard !first.isLocked else {
                // Try again soon; by then the phone has most likely been unlocked.
                completion(Timeline(entries: [first], policy: .after(now.addingTimeInterval(15 * 60))))
                return
            }
            let entries = [first, makeEntry(at: midnight.addingTimeInterval(1))]
            completion(Timeline(entries: entries, policy: .after(midnight.addingTimeInterval(60))))
        }
    }
}

// MARK: - Intent

struct CheckHabitIntent: AppIntent {
    static let title: LocalizedStringResource = "Alışkanlığı işaretle"
    static let isDiscoverable = false

    @Parameter(title: "Alışkanlık") var habitID: String

    init() {}
    init(habitID: String) { self.habitID = habitID }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let container = WidgetStore.container else { return .result() }
        let context = ModelContext(container)
        let all = (try? context.fetch(FetchDescriptor<Habit>())) ?? []
        guard let habit = all.first(where: { $0.id.uuidString == habitID }) else { return .result() }
        let today = DayKey.today()
        let hist = habit.history
        let count = hist.count(on: today)

        if hist.schedule.period != .day {
            count > 0 ? habit.undoOne(on: today, in: context) : habit.check(on: today, in: context)
        } else if count < hist.schedule.timesPerDay {
            habit.check(on: today, in: context)
        } else if hist.schedule.timesPerDay == 1 {
            habit.clear(on: today, in: context)
        }

        // Drop today's reminders that are now satisfied; the app re-plans fully on next launch.
        let newCount = habit.history.count(on: today)
        let ids = (0..<max(newCount, 0)).map { "ilmek|\(habitID)|\(today.rawValue)|\($0)" }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        return .result()
    }
}

// MARK: - Views

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "today", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Bugün")
        .description("Bugünün alışkanlıkları; dokunarak işaretle.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private let accent = YarnColor.terracotta.color

struct TodayWidgetView: View {
    let entry: TodayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.isLocked {
            Label("Kilidi açınca güncellenir", systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .systemSmall: small
        case .systemMedium: medium
        case .systemLarge: large
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        default: Text("🧶 \(entry.done)/\(entry.due)")
        }
    }

    private var fraction: Double { entry.due == 0 ? 0 : Double(entry.done) / Double(entry.due) }

    private var ring: some View {
        ZStack {
            Circle().stroke(accent.opacity(0.18), lineWidth: 9)
            Circle().trim(from: 0, to: fraction)
                .stroke(accent, style: .init(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if entry.due > 0 && entry.done >= entry.due {
                Image(systemName: "checkmark").font(.title2.weight(.bold)).foregroundStyle(accent)
            } else {
                Text("\(entry.done)/\(entry.due)").font(.headline.monospacedDigit())
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Bugün").font(.subheadline.weight(.semibold))
            Spacer()
            if entry.perfectStreak > 0 {
                Text("🔥 \(entry.perfectStreak)").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
        }
    }

    private var small: some View {
        VStack(spacing: 10) {
            header
            ring.frame(width: 78, height: 78)
            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var message: LocalizedStringKey {
        if entry.due == 0 { return "Dinlenme günü" }
        if entry.done >= entry.due { return "İlmek tamam" }
        return "\(entry.due - entry.done) kaldı"
    }

    private var medium: some View {
        HStack(spacing: 16) {
            VStack(spacing: 8) {
                ring.frame(width: 70, height: 70)
                if entry.perfectStreak > 0 {
                    Text("🔥 \(entry.perfectStreak)").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            list(max: 3)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ring.frame(width: 54, height: 54)
                VStack(alignment: .leading) {
                    Text("Bugün").font(.headline)
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if entry.perfectStreak > 0 {
                    Text("🔥 \(entry.perfectStreak)").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            list(max: 7)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func list(max: Int) -> some View {
        if entry.habits.isEmpty {
            Text(entry.due == 0 ? "Bugün için bir şey yok" : "Hepsi tamam 🎉")
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(entry.habits.prefix(max)) { h in
                    Button(intent: CheckHabitIntent(habitID: h.id)) {
                        HStack(spacing: 8) {
                            Text(h.emoji).font(.body)
                            Text(h.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                .strikethrough(h.isDone).foregroundStyle(h.isDone ? .secondary : .primary)
                            Spacer(minLength: 4)
                            if h.target > 1 && !h.isDone {
                                Text("\(h.progress)/\(h.target)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Image(systemName: h.isDone ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(h.color.color)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                if entry.habits.count > max {
                    Text("+\(entry.habits.count - max) daha").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var circular: some View {
        Gauge(value: fraction) {
            Text("🧶")
        } currentValueLabel: {
            Text("\(entry.done)").font(.headline)
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("İlmek").font(.headline).widgetAccentable()
            Text("Bugün \(entry.done)/\(entry.due)")
            if entry.perfectStreak > 0 { Text("🔥 \(entry.perfectStreak) gün") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
