import SwiftUI
import SwiftData
import StoreKit
import IlmekKit

struct TodayView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(filter: #Predicate<Habit> { $0.archivedAt == nil }, sort: \Habit.sortOrder)
    private var habits: [Habit]

    @State private var today = DayKey.today()
    @State private var selected = DayKey.today()
    @State private var editing: Habit?
    @State private var creating = false
    @State private var showSettings = false
    @State private var celebrate = 0
    @Environment(\.requestReview) private var requestReview
    @State private var showNotDue = false

    private var firstWeekday: Int { Calendar.current.firstWeekday }

    var body: some View {
        let items = habits.map { TodayItem(habit: $0, day: selected, today: today, firstWeekday: firstWeekday) }
        let open = items.filter { $0.isDue && !$0.isComplete }
        let closed = items.filter { $0.isDue && $0.isComplete }
        let notDue = items.filter { !$0.isDue }
        let timelines = items.map(\.timeline)

        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    WeekStrip(selected: $selected, today: today, firstWeekday: firstWeekday,
                              timelines: timelines)

                    if habits.isEmpty {
                        emptyState
                    } else {
                        if selected == today, let end = Vacation.until(habits, today: today) {
                            PauseBanner(count: Vacation.paused(habits, today: today).count, end: end) {
                                withAnimation(.snappy) { Vacation.end(habits: habits, in: context) }
                            }
                        }
                        DaySummaryCard(summary: StreakEngine.summary(timelines, on: selected,
                                                                     firstWeekday: firstWeekday),
                                       isToday: selected == today,
                                       celebrate: selected == today ? celebrate : 0)

                        openSections(open)
                        if !closed.isEmpty {
                            section(open.isEmpty ? "Hepsi tamam 🎉" : "Tamamlananlar", closed)
                        }
                        if !notDue.isEmpty {
                            notDueSection(notDue)
                        }
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 32)
                .animation(.snappy, value: items.map(\.animationKey))
            }
            .background(Theme.background)
            .environment(\.selectedDay, selected)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Yeni alışkanlık", systemImage: "plus") { creating = true }
                }
                if selected != today {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Bugün") { withAnimation(.snappy) { selected = today } }
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Ayarlar", systemImage: "gearshape") { showSettings = true }
                    }
                }
            }
            .sheet(isPresented: $creating) { HabitEditorView(habit: nil) }
            .sheet(isPresented: $showSettings) { SettingsSheet() }
            .sheet(item: $editing) { HabitEditorView(habit: $0) }
        }
        .onChange(of: todayDone(timelines)) { was, now in
            guard now && !was else { return }
            celebrate += 1
            askForReviewIfMilestone(timelines)
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshDay() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refreshDay() }
    }

    private var title: String {
        if selected == today { return String(localized: "Bugün") }
        if selected == today.adding(days: -1) { return String(localized: "Dün") }
        return selected.startDate(in: .current).formatted(.dateTime.day().month(.wide).weekday(.wide))
    }

    /// Midnight passed while the app was open or in the background.
    private func refreshDay() {
        let now = DayKey.today()
        guard now != today else { return }
        if selected == today { selected = now }
        today = now
    }

    // MARK: Celebration

    private func todayDone(_ timelines: [HabitTimeline]) -> Bool {
        let s = StreakEngine.summary(timelines, on: today, firstWeekday: firstWeekday)
        return s.due > 0 && s.done >= s.due
    }

    /// Apple's rating prompt, at most once per milestone and only on a good day.
    private func askForReviewIfMilestone(_ timelines: [HabitTimeline]) {
        let streak = StreakEngine.perfectDayStreak(timelines, today: today, firstWeekday: firstWeekday)
        guard [7, 30, 100].contains(streak) else { return }
        let key = "review.asked.\(streak)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        Task {
            try? await Task.sleep(for: .seconds(1.5))   // after the celebration
            requestReview()
        }
    }

    // MARK: Sections

    private func section(_ title: LocalizedStringKey?, _ items: [TodayItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            ForEach(items) { item in
                HabitRow(item: item,
                         onCheck: { check(item) },
                         onEdit: { editing = item.habit })
            }
        }
    }

    /// Still-open habits by part of the day (from their first reminder). With only one part in
    /// play the list stays a single, untitled block.
    @ViewBuilder private func openSections(_ items: [TodayItem]) -> some View {
        let groups = Dictionary(grouping: items) { DayPart($0.habit.reminder) }
        if groups.count <= 1 {
            if !items.isEmpty { section(nil, items) }
        } else {
            ForEach(DayPart.allCases.filter { groups[$0] != nil }, id: \.self) { part in
                let sorted = (groups[part] ?? []).sorted {
                    let a = DayPart.sortKey($0.habit.reminder), b = DayPart.sortKey($1.habit.reminder)
                    return a != b ? a < b : $0.habit.sortOrder < $1.habit.sortOrder
                }
                section(part.title, sorted)
            }
        }
    }

    private func notDueSection(_ items: [TodayItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { showNotDue.toggle() }
            } label: {
                HStack {
                    Text(selected == today ? "Bugün sırası değil" : "O gün sırası değildi")
                    Text("\(items.count)").foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(showNotDue ? 180 : 0))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if showNotDue {
                ForEach(items) { item in
                    HabitRow(item: item, onCheck: { check(item) }, onEdit: { editing = item.habit })
                        .opacity(0.6)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("🧶").font(.system(size: 56))
            Text("İlk ilmeği at").font(.title2.weight(.bold))
            Text("Bir alışkanlık ekle; her gün yaptıkça serin uzasın.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Alışkanlık ekle") { creating = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: Actions

    private func check(_ item: TodayItem) {
        let h = item.habit
        let day = selected
        withAnimation(.snappy) {
            if item.isSkipped {
                h.toggleSkip(on: day, in: context)
            } else if item.isWeekOrMonth {
                // One check per day for weekly/monthly habits; tapping again undoes it.
                item.dayCount > 0 ? h.undoOne(on: day, in: context) : h.check(on: day, in: context)
            } else if item.dayCount < item.target {
                h.check(on: day, in: context)
            } else if item.target == 1 {
                h.clear(on: day, in: context)
            }
        }
    }
}

/// Everything a row needs, computed once per render.
struct TodayItem: Identifiable {
    let habit: Habit
    let timeline: HabitTimeline
    let history: HabitHistory
    let streak: StreakResult        // as of real today
    let dayCount: Int               // completions on the selected day
    let progress: Int               // toward the unit containing the selected day
    let target: Int
    let isDue: Bool
    let isSkipped: Bool
    let isWeekOrMonth: Bool

    var id: PersistentIdentifier { habit.persistentModelID }
    var isComplete: Bool { isSkipped || progress >= target }
    var animationKey: String { "\(habit.id)-\(progress)-\(isSkipped)-\(isDue)" }

    init(habit: Habit, day: DayKey, today: DayKey, firstWeekday: Int) {
        self.habit = habit
        let t = habit.timeline
        timeline = t
        // Past days are judged by the schedule that was in effect then.
        let h = t.history(on: day) ?? t.current
        history = h
        let now = StreakEngine.evaluate(t.current, today: today, firstWeekday: firstWeekday)
        streak = now
        let atDay = day == today && h.startDay == t.current.startDay ? now : StreakEngine.evaluate(h, today: day, firstWeekday: firstWeekday)
        dayCount = h.count(on: day)
        progress = atDay.progress
        target = atDay.target
        isDue = t.history(on: day) != nil && h.schedule.isDue(on: day, start: h.startDay)
        isSkipped = h.skipped.contains(day)
        isWeekOrMonth = h.schedule.period != .day
    }
}
