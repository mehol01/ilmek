import SwiftUI
import SwiftData
import IlmekKit

// MARK: - Habit row

struct HabitRow: View {
    let item: TodayItem
    let onCheck: () -> Void
    let onEdit: () -> Void

    @Environment(\.modelContext) private var context

    private var habit: Habit { item.habit }

    var body: some View {
        HStack(spacing: 14) {
            HabitBadge(emoji: habit.emoji, color: habit.color.color)

            VStack(alignment: .leading, spacing: 3) {
                Text(habit.name)
                    .font(.body.weight(.semibold))
                    .strikethrough(item.isComplete && !item.isSkipped, color: .secondary)
                    .foregroundStyle(item.isComplete ? .secondary : .primary)
                    .lineLimit(2)
                subtitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CheckButton(item: item, color: habit.color.color, action: onCheck)
        }
        .card()
        .contentShape(.rect(cornerRadius: Theme.cardRadius))
        .onTapGesture(perform: onEdit)
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: item.isComplete ? "Geri al" : "Tamamla", onCheck)
    }

    private var subtitle: some View {
        HStack(spacing: 6) {
            if item.isSkipped {
                Label("Atlandı", systemImage: "forward.fill").labelStyle(.titleAndIcon)
            } else {
                if item.streak.current > 0 {
                    Text("🔥 \(item.streak.current)")
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
                if item.target > 1 || item.isWeekOrMonth {
                    Text("\(item.progress)/\(item.target)").monospacedDigit()
                }
                Text(habit.isMedication && !habit.dose.isEmpty ? habit.dose : habit.schedule.summary)
                    .lineLimit(1)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var menu: some View {
        Button("Düzenle", systemImage: "pencil", action: onEdit)
        if item.dayCount > 0 {
            Button("Bir geri al", systemImage: "arrow.uturn.backward") { act { $0.undoOne(on: $1, in: context) } }
        }
        if item.dayCount > 1 {
            Button("Sıfırla", systemImage: "xmark.circle") { act { $0.clear(on: $1, in: context) } }
        }
        if item.isDue {
            Button(item.isSkipped ? "Atlamayı kaldır" : "Atla", systemImage: "forward") {
                act { $0.toggleSkip(on: $1, in: context) }
            }
        }
        Divider()
        Button("Arşivle", systemImage: "archivebox") {
            habit.archivedAt = .now
            context.saveQuietly()
        }
    }

    @Environment(\.selectedDay) private var selectedDay

    private func act(_ f: (Habit, DayKey) -> Void) {
        withAnimation(.snappy) { f(habit, selectedDay) }
    }
}

extension EnvironmentValues {
    @Entry var selectedDay: DayKey = .today()
}

// MARK: - Check button

struct CheckButton: View {
    let item: TodayItem
    let color: Color
    let action: () -> Void

    var body: some View {
        let done = item.isComplete && !item.isSkipped
        Button(action: action) {
            ZStack {
                if item.isSkipped {
                    Circle().fill(Color(.tertiarySystemFill))
                    Image(systemName: "forward.fill").font(.footnote).foregroundStyle(.secondary)
                } else if done {
                    Circle().fill(color)
                    Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    ProgressRing(progress: item.progress, target: item.target, color: color, lineWidth: 3.5)
                    if item.target > 1 && !item.isWeekOrMonth {
                        Text("\(item.dayCount)")
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle(color)
                            .contentTransition(.numericText())
                    }
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(.circle)
        }
        .buttonStyle(PressScaleStyle())
        .sensoryFeedback(.success, trigger: done) { old, new in !old && new }
        .sensoryFeedback(.impact(weight: .light), trigger: item.dayCount)
        .accessibilityLabel(done ? "Tamamlandı" : "Tamamla")
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.5), value: configuration.isPressed)
    }
}

// MARK: - Week strip

struct WeekStrip: View {
    @Binding var selected: DayKey
    let today: DayKey
    let firstWeekday: Int
    let timelines: [HabitTimeline]

    var body: some View {
        let start = selected.startOfWeek(firstWeekday: firstWeekday)
        let symbols = Calendar.current.veryShortWeekdaySymbols
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                let day = start.adding(days: i)
                let isFuture = day > today
                let s = StreakEngine.summary(timelines, on: day, firstWeekday: firstWeekday, forRecord: true)
                Button {
                    withAnimation(.snappy) { selected = day }
                } label: {
                    VStack(spacing: 6) {
                        Text(symbols[day.weekday - 1])
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(day == today ? Color.accentColor : .secondary)
                        ZStack {
                            if day == selected {
                                Circle().fill(Color.accentColor.opacity(0.14))
                            }
                            ProgressRing(progress: isFuture ? 0 : s.done, target: max(s.due, 1),
                                         color: .accentColor, lineWidth: 3)
                                .padding(3)
                                .opacity(isFuture || s.due == 0 ? 0.35 : 1)
                            Text("\(day.day)")
                                .font(.subheadline.weight(day == selected ? .bold : .medium).monospacedDigit())
                                .foregroundStyle(isFuture ? .tertiary : .primary)
                        }
                        .frame(width: 40, height: 40)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(isFuture)
                .accessibilityLabel(day.startDate(in: .current).formatted(date: .complete, time: .omitted))
            }
        }
        .padding(.vertical, 10)
        .card(padding: 6)
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            let target = selected.adding(days: v.translation.width < 0 ? 7 : -7)
            withAnimation(.snappy) { selected = min(target, today) }
        })
        .sensoryFeedback(.selection, trigger: selected)
    }
}

// MARK: - Summary

struct DaySummaryCard: View {
    let summary: DaySummary
    let isToday: Bool
    /// Bumped when today becomes complete: plays the little celebration.
    var celebrate = 0

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                ProgressRing(progress: summary.done, target: max(summary.due, 1), color: .accentColor, lineWidth: 7)
                if summary.due > 0 && summary.done >= summary.due {
                    Image(systemName: "checkmark")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.bounce, value: celebrate)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text(summary.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.footnote.weight(.bold).monospacedDigit())
                        .contentTransition(.numericText())
                }
                YarnBurst(trigger: celebrate)
            }
            .frame(width: 58, height: 58)
            .sensoryFeedback(.success, trigger: celebrate)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(summary.done) / \(summary.due)")
                    .font(.title2.weight(.bold).monospacedDigit())
                    .contentTransition(.numericText())
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .card()
    }

    private var message: LocalizedStringKey {
        if summary.due == 0 { return "Bugün için bir şey yok" }
        if summary.done == summary.due { return isToday ? "Bugünün ilmeği tamam" : "O gün tamamdı" }
        if summary.done == 0 { return isToday ? "Hadi ilk ilmeği at" : "O gün boş kalmış" }
        return isToday ? "Güzel gidiyor" : "Kısmen tamamlanmış"
    }
}

/// Shown on Today while habits are paused (vacation or single pauses).
struct PauseBanner: View {
    let count: Int
    let end: DayKey
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "pause.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) alışkanlık duraklatıldı").font(.subheadline.weight(.semibold))
                Text("Bitiş: \(end.startDate(in: .current).formatted(.dateTime.day().month(.wide)))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Devam ettir", action: onResume)
                .buttonStyle(.bordered).controlSize(.small)
        }
        .card(padding: 14)
    }
}

extension DayPart {
    var title: LocalizedStringKey {
        switch self {
        case .morning: "Sabah"
        case .afternoon: "Öğle"
        case .evening: "Akşam"
        case .anytime: "Gün boyu"
        }
    }
}

/// A small burst of yarn-coloured dots from the ring when the day is done.
struct YarnBurst: View {
    let trigger: Int
    @State private var t = 1.0   // 1 = finished (invisible)

    var body: some View {
        ZStack {
            ForEach(0..<14, id: \.self) { i in
                let angle = Double(i) / 14 * 2 * .pi
                let color = YarnColor.allCases[i % YarnColor.allCases.count].color
                Circle().fill(color)
                    .frame(width: i.isMultiple(of: 2) ? 7 : 5)
                    .offset(x: cos(angle) * 52 * t, y: sin(angle) * 52 * t)
                    .opacity(t < 1 ? 1 - t * t : 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { t = 0 }
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.9)) { t = 1 } }
        }
    }
}
