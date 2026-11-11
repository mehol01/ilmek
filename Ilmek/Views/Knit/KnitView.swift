import SwiftUI
import SwiftData
import IlmekKit

enum KnitMode: String, CaseIterable {
    case scarf, stats
}

/// The scarf: one stitch per day, one row per week, growing downward.
/// People who'd rather see plain numbers can switch the tab to stats; the choice is remembered.
struct KnitView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var habits: [Habit]           // archived included: past days must not change
    @Query(sort: \Stitch.dayRaw) private var stitches: [Stitch]

    @State private var today = DayKey.today()
    @State private var inspected: DayKey?
    @AppStorage("knit.mode") private var storedMode: KnitMode = .scarf
    @AppStorage(Profile.knitEnabledKey) private var knitOn = false
    @State private var showSettings = false

    private var mode: KnitMode { knitOn ? storedMode : .stats }

    var body: some View {
        let model = ScarfModel(habits: habits, stitches: stitches, today: today,
                               firstWeekday: Calendar.current.firstWeekday)
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        if knitOn {
                            Picker("Görünüm", selection: $storedMode) {
                                Text("Atkı").tag(KnitMode.scarf)
                                Text("İstatistik").tag(KnitMode.stats)
                            }
                            .pickerStyle(.segmented)
                        }

                        if !model.hasStarted {
                            ContentUnavailableView(mode == .scarf ? "Atkın burada örülecek" : "İstatistiklerin burada görünecek",
                                                   systemImage: mode == .scarf ? "square.grid.3x3" : "chart.bar",
                                                   description: Text("Bir alışkanlık ekleyince başlar."))
                        } else if mode == .stats {
                            StatsSection(model: model, habits: habits, today: today)
                        } else {
                            YarnPickerCard(selected: model.color(on: today)) { setToday($0) }
                            StatsRow(model: model)
                            VStack(spacing: 10) {
                                if let day = inspected {
                                    StitchInfo(day: day, model: model)
                                        .transition(.move(edge: .top).combined(with: .opacity))
                                }
                                ScarfCanvas(model: model, highlight: inspected) { day in
                                    withAnimation(.snappy) { inspected = inspected == day ? nil : day }
                                }
                                .id("scarf")
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, 32)
                }
                .background(Theme.background)
                .onAppear { if mode == .scarf { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: mode) { _, m in
                    if m == .scarf { DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) } }
                }
            }
            .navigationTitle(knitOn ? "Örgü" : "İstatistik")
            .sheet(isPresented: $showSettings) { SettingsSheet() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Ayarlar", systemImage: "gearshape") { showSettings = true }
                }
                if model.hasStarted && mode == .scarf {
                    ToolbarItem(placement: .topBarTrailing) {
                        // Rendered only when the user actually shares. Rendering it here would redraw
                        // the whole scarf as a huge image on every refresh of this screen.
                        ShareLink(item: ScarfShare(model: model),
                                  preview: SharePreview("Atkım", image: Image(systemName: "square.grid.3x3.fill"))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, p in if p == .active { today = .today() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in today = .today() }
    }

    /// Only today's colour can change. Duplicates from sync are merged into one record.
    private func setToday(_ color: YarnColor) {
        let mine = stitches.filter { $0.dayRaw == today.rawValue }
        if let first = mine.first {
            first.colorName = color.rawValue
            first.updatedAt = .now
            mine.dropFirst().forEach(context.delete)
        } else {
            context.insert(Stitch(day: today, color: color))
        }
        context.saveQuietly()
    }
}

// MARK: - Model

/// Anything the scarf canvas can draw: my own knit or a friend's.
protocol ScarfSource {
    var today: DayKey { get }
    var started: DayKey { get }
    var rows: [[DayKey]] { get }
    func color(on day: DayKey) -> YarnColor
    func fraction(on day: DayKey) -> Double
}

extension ScarfSource {
    func look(_ day: DayKey) -> Knit.StitchLook {
        Knit.look(of: day, today: today, started: started, fraction: fraction(on: day))
    }
    var knittedCount: Int { max(0, started.days(to: today) + 1) }
}

/// A friend's scarf decoded from their published payload.
struct FriendScarf: ScarfSource {
    let payload: ScarfPayload
    let rows: [[DayKey]]
    var today: DayKey { payload.last }
    var started: DayKey { payload.start }

    init(_ payload: ScarfPayload, firstWeekday: Int = Calendar.current.firstWeekday) {
        self.payload = payload
        rows = Knit.rows(started: payload.start, today: payload.last, firstWeekday: firstWeekday)
    }

    func color(on day: DayKey) -> YarnColor {
        let i = Int(payload.entry(on: day)?.color ?? 0)
        return YarnColor.allCases.indices.contains(i) ? YarnColor.allCases[i] : .terracotta
    }

    func fraction(on day: DayKey) -> Double {
        Double(payload.entry(on: day)?.fraction ?? 0) / 255
    }
}

@MainActor
struct ScarfModel: ScarfSource, Sendable {
    let today: DayKey
    let started: DayKey
    let rows: [[DayKey]]
    private let colors: [(day: DayKey, color: YarnColor)]   // sorted, one per day
    private let fractions: [DayKey: Double]
    private let summaryByDay: [DayKey: DaySummary]
    /// One summary per day from `started` through `today`, oldest first.
    let summaries: [DaySummary]
    let hasStarted: Bool

    init(habits: [Habit], stitches: [Stitch], today: DayKey, firstWeekday: Int) {
        self.today = today
        let timelines = habits.map(\.timeline)
        let first = timelines.map(\.firstDay).min()
        hasStarted = first != nil
        started = min(first ?? today, today)
        rows = Knit.rows(started: started, today: today, firstWeekday: firstWeekday)

        var latest: [Int: Stitch] = [:]
        for s in stitches where latest[s.dayRaw].map({ $0.updatedAt < s.updatedAt }) ?? true {
            latest[s.dayRaw] = s
        }
        colors = latest.values.compactMap { s in
            DayKey(rawValue: s.dayRaw).map { ($0, YarnColor(rawValue: s.colorName) ?? .terracotta) }
        }.sorted { $0.day < $1.day }

        var f: [DayKey: Double] = [:]
        var byDay: [DayKey: DaySummary] = [:]
        var list: [DaySummary] = []
        var d = started
        while d <= today {
            let s = StreakEngine.summary(timelines, on: d, firstWeekday: firstWeekday, forRecord: true)
            // A rest day (nothing due) is a full stitch, not a failure.
            f[d] = s.due == 0 ? 1 : s.fraction
            byDay[d] = s
            list.append(s)
            d = d.adding(days: 1)
        }
        fractions = f
        summaryByDay = byDay
        summaries = hasStarted ? list : []
    }

    /// The day's own colour, or the last one picked before it (so unpicked days follow the yarn).
    func color(on day: DayKey) -> YarnColor {
        var lo = 0, hi = colors.count - 1, found: YarnColor?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if colors[mid].day <= day { found = colors[mid].color; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found ?? .terracotta
    }

    func fraction(on day: DayKey) -> Double { fractions[day] ?? 0 }

    func summary(on day: DayKey) -> DaySummary? { summaryByDay[day] }

    /// The whole day for the stats heatmap: rest days stay distinct from misses.
    func cell(on day: DayKey) -> HeatCell {
        guard let s = summaryByDay[day] else { return .none }
        return s.due == 0 ? .rest : .value(min(1, s.fraction))
    }

    var fullCount: Int { fractions.values.filter { $0 >= 1 }.count }

    /// PNG of the whole scarf. The scale drops for long scarves so the image stays a sane size.
    func sharePNG() -> Data? {
        let r = ImageRenderer(content: ScarfCanvas(model: self, highlight: nil, onTap: nil)
            .frame(width: 360).padding(24).background(Color(.systemBackground)))
        r.scale = rows.count > 160 ? 1 : rows.count > 70 ? 2 : 3
        return r.uiImage?.pngData()
    }
}

/// The scarf as a shareable image, produced on demand.
struct ScarfShare: Transferable {
    let model: ScarfModel

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            guard let data = await item.model.sharePNG() else { throw CocoaError(.fileWriteUnknown) }
            return data
        }
    }
}

// MARK: - Canvas

struct ScarfCanvas<Source: ScarfSource>: View {
    let model: Source
    let highlight: DayKey?
    let onTap: ((DayKey) -> Void)?

    private let fringeRatio: CGFloat = 0.9

    var body: some View {
        GeometryReader { geo in
            let cw = geo.size.width / 7
            let rh = cw * 0.72
            let fringe = cw * fringeRatio
            Canvas { ctx, _ in
                drawFringe(ctx, cw: cw, height: fringe)
                for (r, row) in model.rows.enumerated() {
                    for (c, day) in row.enumerated() {
                        let rect = CGRect(x: CGFloat(c) * cw, y: fringe + CGFloat(r) * rh, width: cw, height: rh)
                        drawStitch(ctx, day: day, in: rect)
                    }
                }
            }
            .contentShape(.rect)
            .onTapGesture { p in
                guard let onTap else { return }
                // Int(_:) traps on NaN/infinity, so make sure there is a real size to divide by.
                guard cw > 0, rh > 0, p.x.isFinite, p.y.isFinite, p.y >= fringe else { return }
                let c = Int(p.x / cw), r = Int((p.y - fringe) / rh)
                guard model.rows.indices.contains(r), (0..<7).contains(c) else { return }
                let day = model.rows[r][c]
                if case .empty = model.look(day) { return }
                onTap(day)
            }
        }
        .aspectRatio(7 / (fringeRatio + CGFloat(model.rows.count) * 0.72 + 0.35), contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(Text("Atkı: \(model.knittedCount) ilmek, \(model.rows.count) sıra"))
    }

    private func drawFringe(_ ctx: GraphicsContext, cw: CGFloat, height: CGFloat) {
        guard let firstRow = model.rows.first else { return }
        for (c, day) in firstRow.enumerated() {
            let col = model.color(on: max(day, model.started)).color
            for k in 0..<2 {
                let x = CGFloat(c) * cw + cw * (k == 0 ? 0.36 : 0.64)
                var p = Path()
                p.move(to: CGPoint(x: x, y: height))
                p.addQuadCurve(to: CGPoint(x: x + (k == 0 ? -2 : 2), y: height * 0.12),
                               control: CGPoint(x: x + (k == 0 ? 3 : -3), y: height * 0.55))
                ctx.stroke(p, with: .color(col.opacity(0.8)), style: .init(lineWidth: cw * 0.09, lineCap: .round))
            }
        }
    }

    private func drawStitch(_ ctx: GraphicsContext, day: DayKey, in rect: CGRect) {
        let look = model.look(day)
        let color = model.color(on: day).color
        let isHighlighted = day == highlight

        let f: Double
        switch look {
        case .empty:
            drawLegs(ctx, rect: rect, width: 0.30) { leg, c in
                c.stroke(leg, with: .color(.secondary.opacity(0.18)),
                         style: .init(lineWidth: 1, dash: [2, 2]))
            }
            return
        case .onNeedle(let x), .knitted(let x):
            f = x
        }

        let width = 0.26 + 0.16 * f            // plump when complete
        let alpha = 0.30 + 0.70 * f
        drawLegs(ctx, rect: rect, width: width) { leg, c in
            let b = leg.boundingRect
            c.fill(leg, with: .linearGradient(
                Gradient(colors: [color.opacity(alpha), color.mix(with: .black, by: 0.25).opacity(alpha)]),
                startPoint: CGPoint(x: b.midX, y: b.minY), endPoint: CGPoint(x: b.midX, y: b.maxY)))
            c.stroke(leg, with: .color(color.mix(with: .black, by: 0.35).opacity(alpha * 0.6)), lineWidth: 0.6)
            // Yarn highlight
            var shine = Path()
            shine.move(to: CGPoint(x: b.midX, y: b.minY + b.height * 0.2))
            shine.addLine(to: CGPoint(x: b.midX, y: b.minY + b.height * 0.5))
            c.stroke(shine, with: .color(.white.opacity(0.25 * f)), style: .init(lineWidth: 1, lineCap: .round))
        }

        if case .onNeedle = look {
            let r = rect.insetBy(dx: rect.width * 0.08, dy: -rect.height * 0.05)
            ctx.stroke(Path(roundedRect: r, cornerRadius: 6), with: .color(.accentColor.opacity(0.7)),
                       style: .init(lineWidth: 1.5, dash: [3, 3]))
        }
        if isHighlighted {
            let r = rect.insetBy(dx: rect.width * 0.04, dy: -rect.height * 0.08)
            ctx.stroke(Path(roundedRect: r, cornerRadius: 7), with: .color(.primary), lineWidth: 2)
        }
    }

    /// A knit "V": two leaning ellipses meeting at the bottom.
    private func drawLegs(_ ctx: GraphicsContext, rect: CGRect, width: Double,
                          draw: (Path, GraphicsContext) -> Void) {
        let w = rect.width * width, h = rect.height * 1.18
        for side in [-1.0, 1.0] {
            var c = ctx
            c.translateBy(x: rect.midX + side * rect.width * 0.17, y: rect.midY + rect.height * 0.08)
            c.rotate(by: .degrees(side * 30))
            draw(Path(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h)), c)
        }
    }
}

// MARK: - Pieces

private struct YarnPickerCard: View {
    let selected: YarnColor
    let onPick: (YarnColor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Bugünün ipliği").font(.headline)
                Spacer()
                Text(selected.name).font(.subheadline).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 10) {
                ForEach(YarnColor.allCases) { c in
                    Button { withAnimation(.snappy) { onPick(c) } } label: {
                        Circle().fill(c.color.gradient)
                            .frame(height: 40)
                            .overlay {
                                if c == selected {
                                    Circle().strokeBorder(.background, lineWidth: 3)
                                    Circle().strokeBorder(c.color, lineWidth: 1.5).padding(-3)
                                }
                            }
                            .padding(3)
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel(c.name)
                    .accessibilityAddTraits(c == selected ? .isSelected : [])
                }
            }
            .sensoryFeedback(.selection, trigger: selected)
            Text("Gün bitene kadar değiştirebilirsin. Gece yarısı ilmek kilitlenir.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .card(padding: 16)
    }
}

private struct StatsRow: View {
    let model: ScarfModel

    var body: some View {
        HStack(spacing: 10) {
            stat("\(model.knittedCount)", "ilmek")
            stat("\(model.rows.count)", "sıra")
            stat("\(model.fullCount)", "tam gün")
        }
    }

    private func stat(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .card(padding: 12)
    }
}

private struct StitchInfo: View {
    let day: DayKey
    let model: ScarfModel

    var body: some View {
        let f = model.fraction(on: day)
        let c = model.color(on: day)
        HStack(spacing: 12) {
            Circle().fill(c.color).frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(day.startDate(in: .current).formatted(.dateTime.day().month(.wide).weekday(.wide)))
                    .font(.subheadline.weight(.semibold))
                (Text(c.name) + Text(" · \(f, format: .percent.precision(.fractionLength(0))) tamamlandı"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if day == model.today {
                Text("Örülüyor").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .card(padding: 12)
    }
}
