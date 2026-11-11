import SwiftUI
import IlmekKit

// MARK: - Month calendar (rings)

/// One month in calendar layout; each day is a heatmap tile with its date.
struct MonthCalendar: View {
    let month: DayKey          // first of the month
    let today: DayKey
    let color: Color
    @Binding var selected: DayKey?
    let cell: (DayKey) -> HeatCell

    var body: some View {
        let fw = Calendar.current.firstWeekday
        let lead = (month.weekday - fw + 7) % 7
        let symbols = Calendar.current.veryShortWeekdaySymbols
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { i in
                    Text(symbols[(fw - 1 + i) % 7])
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(0..<(lead + month.daysInMonth), id: \.self) { i in
                    if i < lead {
                        Color.clear.frame(height: 40)
                    } else {
                        let day = month.adding(days: i - lead)
                        let c = cell(day)
                        DayRing(day: day, cell: c, color: color,
                                isToday: day == today, isSelected: day == selected)
                            .onTapGesture {
                                guard c != .none else { return }
                                selected = selected == day ? nil : day
                            }
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}

/// A calendar day as a heatmap tile: same colour scale as the heatmap, with the date on it.
struct DayRing: View {
    let day: DayKey
    let cell: HeatCell
    let color: Color
    var isToday = false
    var isSelected = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let strong: Bool = { if case .value(let v) = cell { return v >= 0.5 }; return false }()
        ZStack {
            switch cell {
            case .none:
                shape.fill(Color(.systemFill).opacity(0.3))
            case .rest:
                shape.strokeBorder(Color(.tertiaryLabel).opacity(0.6), style: .init(lineWidth: 1.5, dash: [3, 2]))
            case .value(let v) where v <= 0:
                shape.fill(Color(.systemFill))
            case .value(let v):
                shape.fill(color.opacity(0.25 + 0.75 * min(v, 1)))
            }
            Text("\(day.day)")
                .font(.caption.weight(isToday ? .heavy : .semibold).monospacedDigit())
                .foregroundStyle(strong ? Color.white : (cell == .none ? Color.secondary.opacity(0.5) : .primary))
        }
        .overlay {
            if isSelected {
                shape.strokeBorder(Color.primary, lineWidth: 2.5)
            } else if isToday {
                shape.strokeBorder(Color.primary.opacity(0.5), lineWidth: 1.5)
            }
        }
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .accessibilityElement()
        .accessibilityLabel(Text(day.startDate(in: .current).formatted(date: .complete, time: .omitted)))
    }
}

// MARK: - Heatmap

/// Weeks as columns (newest on the right), weekdays as rows. Scrolls back to the first day.
struct Heatmap: View {
    let start: DayKey
    let end: DayKey
    let today: DayKey
    let color: Color
    @Binding var selected: DayKey?
    var minWeeks = 18
    let cell: (DayKey) -> HeatCell

    private let size: CGFloat = 15
    private let gap: CGFloat = 3

    var body: some View {
        let fw = Calendar.current.firstWeekday
        let last = end.startOfWeek(firstWeekday: fw)
        let first = min(start.startOfWeek(firstWeekday: fw), last.adding(days: -7 * (minWeeks - 1)))
        let weeks = first.days(to: last) / 7 + 1

        HStack(alignment: .top, spacing: gap) {
            weekdayLabels(fw)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: gap) {
                    ForEach(0..<weeks, id: \.self) { w in
                        column(first.adding(days: 7 * w))
                    }
                }
            }
            .defaultScrollAnchor(.trailing)
        }
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func column(_ weekStart: DayKey) -> some View {
        VStack(spacing: gap) {
            let firstOfMonth = (0..<7).map { weekStart.adding(days: $0) }.first { $0.day == 1 }
            Text(firstOfMonth.map { $0.startDate(in: .current).formatted(.dateTime.month(.abbreviated)) } ?? "")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize()
                .frame(width: size, height: 11, alignment: .leading)
            ForEach(0..<7, id: \.self) { i in
                let day = weekStart.adding(days: i)
                let c = day < start || day > end ? HeatCell.none : cell(day)
                HeatSquare(cell: c, color: color, size: size,
                           isToday: day == today, isSelected: day == selected, faintEmpty: day <= end)
                    .onTapGesture {
                        guard c != .none else { return }
                        selected = selected == day ? nil : day
                    }
            }
        }
    }

    private func weekdayLabels(_ fw: Int) -> some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return VStack(spacing: gap) {
            Color.clear.frame(width: 12, height: 11)
            ForEach(0..<7, id: \.self) { i in
                Text(i % 2 == 0 ? symbols[(fw - 1 + i) % 7] : "")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .frame(width: 12, height: size)
            }
        }
    }
}

struct HeatSquare: View {
    let cell: HeatCell
    let color: Color
    let size: CGFloat
    var isToday = false
    var isSelected = false
    /// Draw untracked days as faint squares so the grid reads as a calendar, not empty space.
    var faintEmpty = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        Group {
            switch cell {
            case .none:
                shape.fill(faintEmpty ? Color(.systemFill).opacity(0.3) : .clear)
            case .rest:
                shape.strokeBorder(Color(.tertiaryLabel).opacity(0.5), style: .init(lineWidth: 1, dash: [2, 1.5]))
            case .value(let v) where v <= 0:
                shape.fill(Color(.systemFill))
            case .value(let v):
                shape.fill(color.opacity(0.25 + 0.75 * min(v, 1)))
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if isSelected {
                shape.strokeBorder(Color.primary, lineWidth: 2)
            } else if isToday {
                shape.strokeBorder(Color.primary.opacity(0.45), lineWidth: 1.5)
            }
        }
    }
}

struct HeatLegend: View {
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text("Az").font(.caption2).foregroundStyle(.secondary)
            ForEach([0.0, 0.34, 0.67, 1.0], id: \.self) { v in
                HeatSquare(cell: .value(v), color: color, size: 11)
            }
            Text("Çok").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            HeatSquare(cell: .rest, color: color, size: 11)
            Text("Dinlenme").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Full-screen calendar

/// Every month (rings) or every year (heatmaps) since tracking began.
struct FullCalendarView: View {
    let title: LocalizedStringKey
    let start: DayKey
    let today: DayKey
    let color: Color
    let cell: (DayKey) -> HeatCell
    /// What to show for a tapped day.
    let detail: (DayKey) -> AnyView

    enum Mode: String { case week, month, year }
    @AppStorage("calendar.mode") private var mode: Mode = .year
    @State private var selected: DayKey?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    Picker("Görünüm", selection: $mode) {
                        Text("Hafta").tag(Mode.week)
                        Text("Ay").tag(Mode.month)
                        Text("Yıl").tag(Mode.year)
                    }
                    .pickerStyle(.segmented)

                    if mode == .week {
                        VStack(spacing: 0) {
                            ForEach(weeks, id: \.self) { w in
                                WeekRow(weekStart: w, start: start, today: today, color: color,
                                        selected: $selected, cell: cell)
                                if w != weeks.last { Divider() }
                            }
                        }
                        .card(padding: 16)
                    } else if mode == .month {
                        ForEach(months, id: \.self) { m in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(m.startDate(in: .current).formatted(.dateTime.month(.wide).year()))
                                    .font(.headline)
                                MonthCalendar(month: m, today: today, color: color, selected: $selected, cell: cell)
                            }
                            .card(padding: 16)
                        }
                    } else {
                        ForEach(years, id: \.self) { y in
                            // The whole calendar year from January (untracked days stay faint).
                            let lo = DayKey(year: y, month: 1, day: 1)
                            let hi = min(today, DayKey(year: y, month: 12, day: 31))
                            VStack(alignment: .leading, spacing: 10) {
                                Text(String(y)).font(.headline)
                                Heatmap(start: lo, end: hi, today: today, color: color, selected: $selected,
                                        minWeeks: 1, cell: { $0 < start ? .none : cell($0) })
                            }
                            .card(padding: 16)
                        }
                        HeatLegend(color: color).padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Kapat") { dismiss() } }
            .sheet(item: Binding(get: { selected.map(SelectedDay.init) }, set: { selected = $0?.day })) { s in
                NavigationStack {
                    ScrollView { detail(s.day).padding(Theme.gutter) }
                        .background(Theme.background)
                        .navigationTitle(Text(s.day.startDate(in: .current).formatted(.dateTime.day().month(.wide).weekday(.wide))))
                        .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var months: [DayKey] {
        var out: [DayKey] = []
        var m = today.firstOfMonth
        while m >= start.firstOfMonth {
            out.append(m)
            m = m.adding(days: -1).firstOfMonth
        }
        return out
    }

    private var weeks: [DayKey] {
        let fw = Calendar.current.firstWeekday
        var out: [DayKey] = []
        var w = today.startOfWeek(firstWeekday: fw)
        let first = start.startOfWeek(firstWeekday: fw)
        while w >= first {
            out.append(w)
            w = w.adding(days: -7)
        }
        return out
    }

    private var years: [Int] { Array((start.year...today.year).reversed()) }
}

private struct SelectedDay: Identifiable {
    let day: DayKey
    var id: Int { day.rawValue }
}

/// One week as seven heatmap tiles, with its date range and completion.
private struct WeekRow: View {
    let weekStart: DayKey
    let start: DayKey
    let today: DayKey
    let color: Color
    @Binding var selected: DayKey?
    let cell: (DayKey) -> HeatCell

    var body: some View {
        let days = (0..<7).map { weekStart.adding(days: $0) }
        let cells = days.map { $0 < start || $0 > today ? HeatCell.none : cell($0) }
        let values = zip(days, cells).compactMap { d, c -> Double? in
            if case .value(let v) = c, d != today || v >= 1 { return min(v, 1) }
            return nil
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(range(days)).font(.subheadline.weight(.semibold))
                Spacer()
                if !values.isEmpty {
                    Text(values.reduce(0, +) / Double(values.count), format: .percent.precision(.fractionLength(0)))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(color)
                }
            }
            HStack(spacing: 4) {
                ForEach(Array(zip(days, cells)), id: \.0) { d, c in
                    DayRing(day: d, cell: c, color: color, isToday: d == today, isSelected: d == selected)
                        .onTapGesture { if c != .none { selected = d } }
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func range(_ days: [DayKey]) -> String {
        let a = days[0].startDate(in: .current), b = days[6].startDate(in: .current)
        return (a..<b.addingTimeInterval(1)).formatted(.interval.day().month(.abbreviated))
    }
}
