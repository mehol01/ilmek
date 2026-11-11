import SwiftUI
import Charts
import IlmekKit

/// The plain alternative to the scarf: calendar, numbers, charts and per-habit details.
struct StatsSection: View {
    let model: ScarfModel
    let habits: [Habit]
    let today: DayKey

    @AppStorage("stats.period") private var period: StatsPeriod = .month
    @State private var selected: DayKey?
    @State private var inspecting: Habit?
    @State private var showCalendar = false
    @State private var showHighlights = false

    private var fw: Int { Calendar.current.firstWeekday }

    var body: some View {
        let streaks = ProgressStats(days: model.summaries)
        let report = PeriodReport(summaries: model.summaries, start: model.started, today: today,
                                  period: period, firstWeekday: fw)
        let active = habits.filter { $0.archivedAt == nil }.sorted { $0.sortOrder < $1.sortOrder }
        let rates = Dictionary(active.map {
            ($0.id, HabitRate.rate($0.timeline, in: report.range, today: today))
        }, uniquingKeysWith: { first, _ in first })
        let hours = CheckInHours.histogram(checkInHours(in: report.range))

        VStack(spacing: 16) {
            calendarCard

            Picker("Dönem", selection: $period.animation(.snappy)) {
                Text("Hafta").tag(StatsPeriod.week)
                Text("Ay").tag(StatsPeriod.month)
                Text("Yıl").tag(StatsPeriod.year)
                Text("Tümü").tag(StatsPeriod.all)
            }
            .pickerStyle(.segmented)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                StatCard(symbol: "chart.pie.fill", tint: .accentColor, label: "Tamamlama") {
                    percent(report.rate)
                } footer: {
                    DeltaText(now: report.rate, before: report.previousRate)
                }
                StatCard(symbol: "checkmark.seal.fill", tint: .green, label: "Tam gün") {
                    Text("\(report.perfectDays)")
                } footer: {
                    Text("\(report.activeDays) gün içinde").font(.caption2).foregroundStyle(.tertiary)
                }
                StatCard(symbol: "flame.fill", tint: .orange, label: "Şu anki seri") {
                    Text("\(streaks.currentStreak) gün")
                } footer: { EmptyView() }
                StatCard(symbol: "trophy.fill", tint: .yellow, label: "En uzun seri") {
                    Text("\(streaks.bestStreak) gün")
                } footer: { EmptyView() }
            }

            TrendCard(report: report, period: period)
            WeekdayCard(rates: report.weekdayRates)
            if hours.reduce(0, +) > 0 { HoursCard(histogram: hours) }

            let insights = Highlights.make(report: report, period: period, hours: hours, habits: active,
                                           rates: rates, start: model.started, today: today,
                                           bestStreak: streaks.bestStreak)
            if !insights.isEmpty {
                Button { showHighlights = true } label: { HighlightsRow(insights: insights) }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showHighlights) { HighlightsSheet(insights: insights, period: period) }
            }

            if !active.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Alışkanlıklar").font(.headline).padding(.bottom, 6)
                    ForEach(active) { h in
                        Button { inspecting = h } label: {
                            HabitStatRow(habit: h, today: today, rate: rates[h.id] ?? nil)
                        }
                        .buttonStyle(.plain)
                        if h.id != active.last?.id { Divider().padding(.leading, 48) }
                    }
                }
                .card(padding: 16)
            }
        }
        .sheet(item: $inspecting) { HabitStatsSheet(habit: $0, today: today) }
        .sheet(isPresented: $showCalendar) {
            FullCalendarView(title: "Takvim", start: model.started, today: today, color: .accentColor,
                             cell: { model.cell(on: $0) },
                             detail: { AnyView(DayHabitsList(day: $0, habits: habits, today: today)) })
        }
    }

    private var calendarCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Takvim").font(.headline)
                Spacer()
                Button {
                    showCalendar = true
                } label: {
                    Label("Tüm takvim", systemImage: "arrow.up.left.and.arrow.down.right")
                        .labelStyle(.iconOnly)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(Color(.tertiarySystemFill), in: .circle)
                }
                .buttonStyle(.plain)
            }
            Heatmap(start: model.started, end: today, today: today, color: .accentColor, selected: $selected) {
                model.cell(on: $0)
            }
            if let selected {
                Divider()
                DayHabitsList(day: selected, habits: habits, today: today, compact: true)
                    .transition(.opacity)
            } else {
                HeatLegend(color: .accentColor)
            }
        }
        .card(padding: 16)
        .animation(.snappy, value: selected)
    }

    private func percent(_ r: Double?) -> Text {
        r.map { Text($0, format: .percent.precision(.fractionLength(0))) } ?? Text("—")
    }

    /// Hours of the day when habits were checked off within `range`.
    private func checkInHours(in range: ClosedRange<DayKey>) -> [Int] {
        let lo = range.lowerBound.rawValue, hi = range.upperBound.rawValue
        let cal = Calendar.current
        var out: [Int] = []
        for h in habits {
            for log in h.logs ?? [] where log.kind == .done && log.dayRaw >= lo && log.dayRaw <= hi {
                out.append(cal.component(.hour, from: log.timestamp))
            }
        }
        return out
    }
}

// MARK: - Per-habit rate

enum HabitRate {
    /// Average completion of a habit's due days in `range`. An unfinished today is left out.
    static func rate(_ t: HabitTimeline, in range: ClosedRange<DayKey>, today: DayKey) -> Double? {
        var sum = 0.0, n = 0
        var d = range.lowerBound
        while d <= range.upperBound {
            if case .value(let v) = t.cell(on: d, today: today), d != today || v >= 1 {
                sum += min(v, 1); n += 1
            }
            d = d.adding(days: 1)
        }
        return n > 0 ? sum / Double(n) : nil
    }

    static func weekdayRates(_ t: HabitTimeline, from: DayKey, today: DayKey) -> [Int: Double] {
        var sum: [Int: Double] = [:], n: [Int: Int] = [:]
        var d = from
        while d <= today {
            if case .value(let v) = t.cell(on: d, today: today), d != today || v >= 1 {
                sum[d.weekday, default: 0] += min(v, 1); n[d.weekday, default: 0] += 1
            }
            d = d.adding(days: 1)
        }
        return n.reduce(into: [:]) { $0[$1.key] = (sum[$1.key] ?? 0) / Double($1.value) }
    }
}

// MARK: - Cards

struct StatCard<Value: View, Footer: View>: View {
    let symbol: String
    let tint: Color
    let label: LocalizedStringKey
    @ViewBuilder let value: Value
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.subheadline).foregroundStyle(tint)
            value.font(.title2.weight(.bold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            HStack(spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                footer
            }
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}

private struct DeltaText: View {
    let now: Double?
    let before: Double?

    var body: some View {
        if let now, let before {
            let diff = now - before
            if abs(diff) >= 0.005 {
                Label {
                    Text(abs(diff), format: .percent.precision(.fractionLength(0)))
                } icon: {
                    Image(systemName: diff > 0 ? "arrow.up" : "arrow.down")
                }
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(diff > 0 ? .green : .orange)
                .accessibilityLabel(Text(diff > 0 ? "öncekinden iyi" : "öncekinden düşük"))
            }
        }
    }
}

private struct ChartCard<Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: Text?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { subtitle.font(.subheadline).foregroundStyle(.secondary) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }
}

private struct TrendCard: View {
    let report: PeriodReport
    let period: StatsPeriod

    var body: some View {
        let unit: Calendar.Component = switch report.trend.first?.days ?? 1 {
        case 1: .day
        case 2...7: .weekOfYear
        default: .month
        }
        ChartCard(title: "Gidişat", subtitle: Text(subtitle)) {
            Chart(report.trend) { b in
                BarMark(x: .value("Tarih", b.start.startDate(in: .current), unit: unit),
                        y: .value("Oran", b.rate ?? 0))
                    .foregroundStyle(Color.accentColor.opacity(b.rate == nil ? 0.2 : 0.35 + 0.65 * (b.rate ?? 0)))
                    .cornerRadius(3)
            }
            .chartYScale(domain: 0...1)
            .chartYAxis {
                AxisMarks(values: [0, 0.5, 1]) { v in
                    AxisGridLine()
                    AxisValueLabel { Text(v.as(Double.self) ?? 0, format: .percent) }
                }
            }
            .chartXAxis {
                AxisMarks(values: axisDates(unit)) { _ in
                    AxisValueLabel(format: unit == .month ? .dateTime.month(.abbreviated)
                                   : unit == .weekOfYear ? .dateTime.day().month(.abbreviated)
                                   : period == .week ? .dateTime.weekday(.narrow) : .dateTime.day())
                }
            }
            .frame(height: 150)
        }
    }

    /// One label per bar for a week, otherwise a handful spread evenly (no half-day ticks).
    private func axisDates(_ unit: Calendar.Component) -> [Date] {
        let dates = report.trend.map { $0.start.startDate(in: .current) }
        guard dates.count > 7 else { return dates }
        let step = Int((Double(dates.count) / 5).rounded(.up))
        return stride(from: 0, to: dates.count, by: step).map { dates[$0] }
    }

    private var subtitle: LocalizedStringKey {
        switch report.trend.first?.days ?? 1 {
        case 1: "Günlük tamamlama"
        case 2...7: "Haftalık tamamlama"
        default: "Aylık tamamlama"
        }
    }
}

private struct WeekdayCard: View {
    let rates: [Int: Double]

    var body: some View {
        let fw = Calendar.current.firstWeekday
        let symbols = Calendar.current.shortWeekdaySymbols
        let order = (0..<7).map { (fw - 1 + $0) % 7 + 1 }
        // Say something only with most weekdays seen, and only if they really differ.
        let enough = rates.count >= 5
        let best = enough ? rates.max { $0.value < $1.value } : nil
        let worst = enough ? rates.min { $0.value < $1.value } : nil
        let standout = best.flatMap { b in worst.map { w in b.value - w.value >= 0.1 } } ?? false

        ChartCard(title: "Haftanın günleri", subtitle: best.flatMap { b in
            worst.map { w in
                b.value - w.value >= 0.1
                    ? Text("En iyi günün \(symbols[b.key - 1]), en zor günün \(symbols[w.key - 1]).")
                    : Text("Haftanın her günü dengelisin.")
            }
        }) {
            Chart(order, id: \.self) { wd in
                BarMark(x: .value("Gün", symbols[wd - 1]), y: .value("Oran", rates[wd] ?? 0))
                    .foregroundStyle(standout && wd != best?.key ? Color.accentColor.opacity(0.45) : Color.accentColor)
                    .cornerRadius(4)
            }
            .chartYScale(domain: 0...1)
            .chartYAxis {
                AxisMarks(values: [0, 0.5, 1]) { v in
                    AxisGridLine()
                    AxisValueLabel { Text(v.as(Double.self) ?? 0, format: .percent) }
                }
            }
            .frame(height: 130)
        }
    }
}

private struct HoursCard: View {
    let histogram: [Int]

    var body: some View {
        let peak = CheckInHours.peak(histogram)
        ChartCard(title: "Saatler", subtitle: peak.map { p in
            switch p {
            case .morning: Text("Alışkanlıklarını çoğunlukla sabah yapıyorsun.")
            case .afternoon: Text("Alışkanlıklarını çoğunlukla öğleden sonra yapıyorsun.")
            default: Text("Alışkanlıklarını çoğunlukla akşam yapıyorsun.")
            }
        }) {
            Chart(Array(histogram.enumerated()), id: \.offset) { h, n in
                BarMark(x: .value("Saat", h), y: .value("İşaret", n))
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(2)
            }
            .chartXScale(domain: 0...23)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { v in
                    AxisValueLabel { Text(String(format: "%02d", v.as(Int.self) ?? 0)) }
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 100)
        }
    }
}

// MARK: - Day detail

/// What happened with each habit on one day.
struct DayHabitsList: View {
    let day: DayKey
    let habits: [Habit]
    let today: DayKey
    var compact = false

    var body: some View {
        let rows = habits.sorted { $0.sortOrder < $1.sortOrder }.compactMap { h -> (Habit, HeatCell, Int)? in
            let t = h.timeline
            guard t.history(on: day) != nil else { return nil }
            let c = t.cell(on: day, today: today)
            return c == .none ? nil : (h, c, h.history.count(on: day))
        }
        VStack(alignment: .leading, spacing: 10) {
            if !compact {
                EmptyView()
            } else {
                Text(day.startDate(in: .current).formatted(.dateTime.day().month(.wide).weekday(.wide)))
                    .font(.subheadline.weight(.semibold))
            }
            if rows.isEmpty {
                Text("O gün takip edilen bir alışkanlık yok.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.0.id) { h, c, count in
                HStack(spacing: 10) {
                    Text(h.emoji)
                    Text(h.name).font(.subheadline).lineLimit(1)
                    Spacer(minLength: 4)
                    status(h, c, count)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func status(_ h: Habit, _ c: HeatCell, _ count: Int) -> some View {
        let color = h.color.color
        switch c {
        case .rest:
            Text(h.history.skipped.contains(day) ? "Atlandı" : "Sırası değil")
                .font(.caption).foregroundStyle(.secondary)
        case .value(let v) where v >= 1:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(color)
        case .value(let v) where v > 0:
            Text("\(count)/\(h.schedule.timesPerDay)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        case .value:
            Image(systemName: day == today ? "circle" : "xmark.circle")
                .foregroundStyle(day == today ? Color.secondary : Color.orange)
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Habits

private struct HabitStatRow: View {
    let habit: Habit
    let today: DayKey
    let rate: Double?

    var body: some View {
        let r = StreakEngine.evaluate(habit.history, today: today, firstWeekday: Calendar.current.firstWeekday)
        HStack(spacing: 12) {
            HabitBadge(emoji: habit.emoji, color: habit.color.color, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(habit.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(streakText(r)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Group {
                if let rate {
                    Text(rate, format: .percent.precision(.fractionLength(0)))
                } else {
                    Text("—")
                }
            }
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(habit.color.color)
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
    }
}

func streakText(_ r: StreakResult) -> String {
    switch r.unit {
    case .day: String(localized: "🔥 \(r.current) gün · en uzun \(r.best)")
    case .week: String(localized: "🔥 \(r.current) hafta · en uzun \(r.best)")
    case .month: String(localized: "🔥 \(r.current) ay · en uzun \(r.best)")
    }
}

private struct HabitStatsSheet: View {
    let habit: Habit
    let today: DayKey
    @Environment(\.dismiss) private var dismiss
    @State private var selected: DayKey?
    @State private var showCalendar = false

    var body: some View {
        let fw = Calendar.current.firstWeekday
        let r = StreakEngine.evaluate(habit.history, today: today, firstWeekday: fw)
        let timeline = habit.timeline
        let total = habit.history.counts.values.reduce(0, +)
        let color = habit.color.color
        let month30 = HabitRate.rate(timeline, in: max(timeline.firstDay, today.adding(days: -29))...today, today: today)
        let weekdays = HabitRate.weekdayRates(timeline, from: max(timeline.firstDay, today.adding(days: -364)), today: today)

        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 6) {
                        HabitBadge(emoji: habit.emoji, color: color, size: 60)
                        Text(habit.name).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                        Text(habit.schedule.summary).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                        StatCard(symbol: "flame.fill", tint: .orange, label: unitLabel(r.unit, current: true)) {
                            Text("\(r.current)")
                        } footer: { EmptyView() }
                        StatCard(symbol: "trophy.fill", tint: .yellow, label: unitLabel(r.unit, current: false)) {
                            Text("\(r.best)")
                        } footer: { EmptyView() }
                        StatCard(symbol: "chart.pie.fill", tint: color, label: "Son 30 gün") {
                            month30.map { Text($0, format: .percent.precision(.fractionLength(0))) } ?? Text("—")
                        } footer: { EmptyView() }
                        StatCard(symbol: "checkmark.circle.fill", tint: .green, label: "toplam") {
                            Text("\(total)")
                        } footer: { EmptyView() }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Takvim").font(.headline)
                            Spacer()
                            Button { showCalendar = true } label: {
                                Label("Tüm takvim", systemImage: "arrow.up.left.and.arrow.down.right")
                                    .labelStyle(.iconOnly)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(width: 32, height: 32)
                                    .background(Color(.tertiarySystemFill), in: .circle)
                            }
                            .buttonStyle(.plain)
                        }
                        Heatmap(start: timeline.firstDay, end: today, today: today, color: color, selected: $selected) {
                            timeline.cell(on: $0, today: today)
                        }
                        if let selected {
                            Divider()
                            DayHabitsList(day: selected, habits: [habit], today: today, compact: true)
                        } else {
                            HeatLegend(color: color)
                        }
                    }
                    .card(padding: 16)
                    .animation(.snappy, value: selected)

                    if weekdays.count >= 3 { WeekdayCard(rates: weekdays) }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .toolbar { Button("Kapat") { dismiss() } }
            .sheet(isPresented: $showCalendar) {
                FullCalendarView(title: LocalizedStringKey(habit.name), start: timeline.firstDay, today: today,
                                 color: color, cell: { timeline.cell(on: $0, today: today) },
                                 detail: { AnyView(DayHabitsList(day: $0, habits: [habit], today: today)) })
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func unitLabel(_ unit: Schedule.Period, current: Bool) -> LocalizedStringKey {
        switch (unit, current) {
        case (.day, true): "gün · şu anki"
        case (.day, false): "gün · en uzun"
        case (.week, true): "hafta · şu anki"
        case (.week, false): "hafta · en uzun"
        case (.month, true): "ay · şu anki"
        case (.month, false): "ay · en uzun"
        }
    }
}

// MARK: - Highlights

struct Insight: Identifiable {
    let id: String
    let symbol: String
    let tint: Color
    let text: Text
    var value: Text?
}

enum Highlights {
    @MainActor
    static func make(report: PeriodReport, period: StatsPeriod, hours: [Int], habits: [Habit],
                     rates: [UUID: Double?], start: DayKey, today: DayKey, bestStreak: Int) -> [Insight] {
        var out: [Insight] = []
        let pct = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))

        if let r = report.rate, let p = report.previousRate, abs(r - p) >= 0.05 {
            out.append(Insight(id: "trend", symbol: r > p ? "arrow.up.right" : "arrow.down.right",
                               tint: r > p ? .green : .orange,
                               text: r > p ? Text("Önceki döneme göre daha iyisin.")
                                           : Text("Önceki döneme göre biraz düştün."),
                               value: Text(verbatim: "\(r > p ? "+" : "−")\(abs(r - p).formatted(pct))")))
        }

        let ranked = habits.compactMap { h in rates[h.id].flatMap { $0 }.map { (h, $0) } }.sorted { $0.1 > $1.1 }
        if ranked.count > 1, let (h, r) = ranked.first {
            out.append(Insight(id: "best", symbol: "star.fill", tint: .yellow,
                               text: Text("En istikrarlı: \(h.emoji) \(h.name)"), value: Text(r.formatted(pct))))
        }
        if ranked.count > 1, let (h, r) = ranked.last, r < 0.8 {
            out.append(Insight(id: "worst", symbol: "tortoise.fill", tint: .orange,
                               text: Text("En çok zorlandığın: \(h.emoji) \(h.name)"), value: Text(r.formatted(pct))))
        }

        // Most improved vs the previous window of the same length.
        if let n = period.length, report.range.lowerBound > start {
            let lo = report.range.lowerBound
            let prev = max(start, lo.adding(days: -n))...lo.adding(days: -1)
            let gains = habits.compactMap { h -> (Habit, Double)? in
                guard let now = rates[h.id] ?? nil,
                      let before = HabitRate.rate(h.timeline, in: prev, today: today) else { return nil }
                return (h, now - before)
            }
            if let (h, g) = gains.max(by: { $0.1 < $1.1 }), g >= 0.1 {
                out.append(Insight(id: "improved", symbol: "chart.line.uptrend.xyaxis", tint: .green,
                                   text: Text("En çok gelişen: \(h.emoji) \(h.name)"),
                                   value: Text(verbatim: "+\(g.formatted(pct))")))
            }
        }

        let wd = report.weekdayRates
        if wd.count >= 5, let b = wd.max(by: { $0.value < $1.value }), let w = wd.min(by: { $0.value < $1.value }),
           b.value - w.value >= 0.1 {
            let names = Calendar.current.weekdaySymbols
            out.append(Insight(id: "bestday", symbol: "calendar", tint: .accentColor,
                               text: Text("En iyi günün: \(names[b.key - 1])"), value: Text(b.value.formatted(pct))))
            out.append(Insight(id: "worstday", symbol: "calendar.badge.exclamationmark", tint: .orange,
                               text: Text("En zor günün: \(names[w.key - 1])"), value: Text(w.value.formatted(pct))))
        }

        if let part = CheckInHours.peak(hours) {
            let text: Text = switch part {
            case .morning: Text("Alışkanlıklarını çoğunlukla sabah yapıyorsun.")
            case .afternoon: Text("Alışkanlıklarını çoğunlukla öğleden sonra yapıyorsun.")
            default: Text("Alışkanlıklarını çoğunlukla akşam yapıyorsun.")
            }
            out.append(Insight(id: "hours", symbol: "clock.fill", tint: .indigo, text: text))
        }

        if report.completed > 0 {
            out.append(Insight(id: "completed", symbol: "checkmark.circle.fill", tint: .green,
                               text: Text("Bu dönemde \(report.completed) kez tamamladın.")))
        }
        if bestStreak > 1 {
            out.append(Insight(id: "streak", symbol: "trophy.fill", tint: .yellow,
                               text: Text("En uzun tam gün serin: \(bestStreak) gün")))
        }
        return out
    }
}

private struct InsightRow: View {
    let insight: Insight

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: insight.symbol).foregroundStyle(insight.tint).frame(width: 24)
            insight.text.font(.subheadline).lineLimit(2)
            Spacer(minLength: 4)
            insight.value?
                .font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// Compact card on the stats page: the headline insight, tap for all of them.
private struct HighlightsRow: View {
    let insights: [Insight]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Öne çıkanlar").font(.headline)
                Spacer()
                if insights.count > 1 {
                    Text(verbatim: "\(insights.count)")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            if let first = insights.first { InsightRow(insight: first) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
        .contentShape(.rect)
    }
}

private struct HighlightsSheet: View {
    let insights: [Insight]
    let period: StatsPeriod
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(insights) { InsightRow(insight: $0).padding(.vertical, 4) }
                } footer: {
                    Text(periodText)
                }
            }
            .navigationTitle("Öne çıkanlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Kapat") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var periodText: LocalizedStringKey {
        switch period {
        case .week: "Son 7 güne göre."
        case .month: "Son 30 güne göre."
        case .year: "Son 1 yıla göre."
        case .all: "Başladığından beri."
        }
    }
}
