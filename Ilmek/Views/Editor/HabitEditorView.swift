import SwiftUI
import SwiftData
import IlmekKit

/// Add or edit a habit. Pass `habit: nil` to create.
struct HabitEditorView: View {
    let habit: Habit?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allHabits: [Habit]

    @State private var draft: HabitDraft
    @State private var showEmojiPicker = false
    @State private var confirmDelete = false
    /// Set before deleting, so no section reads the habit while the sheet animates away.
    @State private var deleted = false
    @State private var notificationsDenied = false
    @FocusState private var nameFocused: Bool

    init(habit: Habit?) {
        self.habit = habit
        _draft = State(initialValue: habit.map(HabitDraft.init) ?? HabitDraft())
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                kindSection
                FrequencySection(draft: $draft)
                ReminderSection(draft: $draft, denied: notificationsDenied)
                shareSection
                if let habit, !deleted {
                    if habit.archivedAt == nil { PauseSection(habit: habit) }
                    dangerSection
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(habit == nil ? "Yeni alışkanlık" : "Düzenle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet", action: save).disabled(!draft.isValid)
                }
            }
            .sheet(isPresented: $showEmojiPicker) {
                EmojiPicker(selection: $draft.emoji)
                    .presentationDetents([.medium, .large])
            }
            .confirmationDialog("Bu alışkanlık ve tüm geçmişi silinsin mi?", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Sil", role: .destructive, action: delete)
            } message: {
                Text("Bu işlem geri alınamaz. Geçmişi saklamak için arşivleyebilirsin.")
            }
            .onAppear { if habit == nil { nameFocused = true } }
            .task { notificationsDenied = await Reminders.shared.isDenied() }
        }
    }

    // MARK: Sections

    private var identitySection: some View {
        Section {
            HStack(spacing: 14) {
                Button { showEmojiPicker = true } label: {
                    HabitBadge(emoji: draft.emoji, color: draft.color.color, size: 56)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Simge seç")

                TextField(draft.isMedication ? "İlaç adı" : "Örn. Kitap oku", text: $draft.name)
                    .font(.title3.weight(.semibold))
                    .focused($nameFocused)
                    .submitLabel(.done)
            }
            .padding(.vertical, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(YarnColor.allCases) { c in
                        Button { draft.color = c } label: {
                            Circle().fill(c.color)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    if draft.color == c {
                                        Circle().strokeBorder(.background, lineWidth: 3)
                                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c.name)
                        .accessibilityAddTraits(draft.color == c ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var kindSection: some View {
        Section {
            Picker("Tür", selection: $draft.isMedication) {
                Text("Alışkanlık").tag(false)
                Text("İlaç / takviye").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: draft.isMedication) { _, isMed in
                // Medicines are private by default and usually want a reminder.
                if habit == nil {
                    draft.isShared = !isMed
                    if isMed && draft.reminderKind == .none { draft.reminderKind = .times }
                    if isMed && draft.emoji == "✨" { draft.emoji = "💊" }
                    if !isMed && draft.emoji == "💊" { draft.emoji = "✨" }
                }
            }
            if draft.isMedication {
                TextField("Doz (örn. 1 tablet, 5 ml)", text: $draft.dose)
            }
        } footer: {
            if draft.isMedication {
                Text("İlmek bir hatırlatıcıdır, tıbbi tavsiye vermez. Dozlar için doktoruna danış.\n\nRahatsız Etme açıkken de gelsin istersen: Ayarlar › Odak › Rahatsız Etme › Uygulamalar › Zamana Duyarlı Bildirimler.")
            }
        }
    }

    private var shareSection: some View {
        Section {
            Toggle("Arkadaşlarımla paylaş", isOn: $draft.isShared)
        } footer: {
            Text(draft.isShared
                 ? "Gruplarındaki arkadaşların bu alışkanlığı ve bugün yapıp yapmadığını görür."
                 : "Gizli: arkadaşların bunu hiç görmez; onlara görünen toplam sayıya ve seriye de eklenmez.")
        }
    }

    private var dangerSection: some View {
        Section {
            Button(habit?.archivedAt == nil ? "Arşivle" : "Arşivden çıkar") {
                guard let habit else { return }
                habit.archivedAt = habit.archivedAt == nil ? .now : nil
                context.saveQuietly()
                dismiss()
            }
            Button("Sil", role: .destructive) { confirmDelete = true }
        } footer: {
            Text("Arşivlenen alışkanlık listeden kalkar, geçmişi ve serisi korunur.")
        }
    }

    // MARK: Actions

    private func save() {
        guard draft.isValid else { return }
        if let habit {
            draft.apply(to: habit)
        } else {
            let next = (allHabits.map(\.sortOrder).max() ?? -1) + 1
            context.insert(draft.makeHabit(sortOrder: next))
        }
        context.saveQuietly()
        if draft.reminderKind != .none {
            Task {
                if await Reminders.shared.requestAuthorizationIfNeeded() { Reminders.shared.scheduleSoon() }
            }
        }
        dismiss()
    }

    private func delete() {
        guard let habit else { return }
        deleted = true
        dismiss()
        context.delete(habit)
        context.saveQuietly()
    }
}

// MARK: - Pause

private struct PauseSection: View {
    let habit: Habit
    @Environment(\.modelContext) private var context
    @State private var until = DayKey.today().adding(days: 7).startDate(in: .current)

    var body: some View {
        let today = DayKey.today()
        Section {
            if let end = habit.pausedThrough(today: today) {
                LabeledContent("Duraklatıldı") {
                    Text(end.startDate(in: .current).formatted(.dateTime.day().month(.wide)))
                }
                Button("Şimdi devam ettir", systemImage: "play.fill") {
                    withAnimation { habit.resume(from: today, in: context) }
                }
            } else {
                DatePicker("Şu tarihe kadar", selection: $until,
                           in: today.adding(days: 1).startDate(in: .current)...today.adding(days: 365).startDate(in: .current),
                           displayedComponents: .date)
                Button("Duraklat", systemImage: "pause.fill") {
                    withAnimation {
                        habit.pause(from: today, through: DayKey(until, calendar: .current), in: context)
                    }
                }
            }
        } header: {
            Text("Duraklat")
        } footer: {
            Text("Tatil, hastalık ya da ara verdiğin günler serini bozmaz ve hatırlatma gelmez.")
        }
    }
}

// MARK: - Frequency

private struct FrequencySection: View {
    @Binding var draft: HabitDraft

    var body: some View {
        Section {
            Picker("Sıklık", selection: $draft.pattern) {
                ForEach(HabitDraft.PatternKind.allCases) { Text($0.title).tag($0) }
            }

            switch draft.pattern {
            case .everyDay:
                EmptyView()
            case .weekdays:
                WeekdayChips(selection: $draft.weekdays)
            case .timesPerWeek:
                Stepper("Haftada \(draft.timesPerWeek) kez", value: $draft.timesPerWeek, in: 1...7)
            case .everyNDays:
                Stepper("\(draft.everyN) günde bir", value: $draft.everyN, in: 2...30)
            case .daysOfMonth:
                MonthDayGrid(selection: $draft.monthDays)
            case .timesPerMonth:
                Stepper("Ayda \(draft.timesPerMonth) kez", value: $draft.timesPerMonth, in: 1...31)
            }

            if draft.pattern.isDayBased {
                if let doses = draft.dosesFromReminder {
                    LabeledContent("Günde", value: String(localized: "\(doses) doz"))
                } else {
                    Stepper("Günde \(draft.timesPerDay) kez", value: $draft.timesPerDay, in: 1...30)
                }
            }
        } header: {
            Text("Sıklık")
        } footer: {
            if draft.dosesFromReminder != nil {
                Text("Doz sayısı hatırlatma saatlerinden hesaplanır.")
            } else if draft.pattern == .daysOfMonth {
                Text("31 seçersen her ayın son günü sayılır.")
            }
        }
    }
}

private struct WeekdayChips: View {
    @Binding var selection: Set<Int>

    var body: some View {
        let names = Calendar.current.veryShortWeekdaySymbols
        HStack(spacing: 6) {
            ForEach(Weekdays.ordered, id: \.self) { wd in
                let on = selection.contains(wd)
                Button {
                    if on { if selection.count > 1 { selection.remove(wd) } } else { selection.insert(wd) }
                } label: {
                    Text(names[wd - 1])
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: .circle)
                        .foregroundStyle(on ? .white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[wd - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

private struct MonthDayGrid: View {
    @Binding var selection: Set<Int>

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
            ForEach(1...31, id: \.self) { day in
                let on = selection.contains(day)
                Button {
                    if on { if selection.count > 1 { selection.remove(day) } } else { selection.insert(day) }
                } label: {
                    Text("\(day)")
                        .font(.footnote.weight(.medium).monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(on ? Color.accentColor : Color(.tertiarySystemFill),
                                    in: .rect(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(on ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: - Reminders

private struct ReminderSection: View {
    @Binding var draft: HabitDraft
    let denied: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Picker("Hatırlatma", selection: $draft.reminderKind) {
                ForEach(HabitDraft.ReminderKind.allCases) { Text($0.title).tag($0) }
            }

            switch draft.reminderKind {
            case .none:
                EmptyView()
            case .times:
                ForEach(draft.times.indices, id: \.self) { i in
                    // Not `$draft.times[i]`: after a swipe-to-delete SwiftUI may still read the
                    // removed row's binding once, and an out-of-range index is a crash.
                    DatePicker(draft.times.count > 1 ? "Saat \(i + 1)" : "Saat",
                               selection: Binding(
                                   get: { draft.times.indices.contains(i) ? draft.times[i] : .now },
                                   set: { if draft.times.indices.contains(i) { draft.times[i] = $0 } }),
                               displayedComponents: .hourAndMinute)
                }
                .onDelete { idx in
                    if draft.times.count > idx.count { draft.times.remove(atOffsets: idx) }
                }
                if draft.times.count < 24 {
                    Button("Saat ekle", systemImage: "plus") {
                        let last = draft.times.last ?? TimeOfDay(hour: 9).date
                        let next = min(last.addingTimeInterval(3 * 3600),
                                       TimeOfDay(hour: 23, minute: 0).date)
                        draft.times.append(next)
                    }
                }
            case .interval:
                Stepper("Her \(draft.intervalHours) saatte bir", value: $draft.intervalHours, in: 1...12)
                DatePicker("Başlangıç", selection: $draft.intervalStart, displayedComponents: .hourAndMinute)
                DatePicker("Bitiş", selection: $draft.intervalEnd, displayedComponents: .hourAndMinute)
            }
        } header: {
            Text("Hatırlatma")
        } footer: {
            if denied && draft.reminderKind != .none {
                Button("Bildirimler kapalı. Açmak için dokun.") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                .font(.footnote)
            } else if draft.reminderKind == .interval {
                let slots = draft.reminder.slots
                if slots.isEmpty || TimeOfDay(draft.intervalStart) > TimeOfDay(draft.intervalEnd) {
                    Text("Bitiş saati başlangıçtan sonra olmalı.")
                } else {
                    Text(slots.map(\.formatted).joined(separator: " · "))
                }
            }
        }
    }
}

// MARK: - Emoji picker

struct EmojiPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""

    static let groups: [(LocalizedStringKey, [String])] = [
        ("Sağlık", ["💧", "💊", "🩺", "🦷", "😴", "🧘", "🫁", "🥗", "🍎", "🥛", "☕️", "🚭"]),
        ("Spor", ["🏃", "🚶", "🏋️", "🚴", "🏊", "⚽️", "🧗", "🤸", "🥊", "🎾", "⛹️", "🧎"]),
        ("Zihin", ["📚", "✍️", "🧠", "🎓", "🗣️", "🌍", "🎹", "🎸", "🎨", "📷", "🧩", "💻"]),
        ("Ev & hayat", ["🧹", "🪴", "🐶", "🛏️", "🍳", "🧺", "💰", "📵", "🙏", "📞", "❤️", "🌅"]),
        ("Diğer", ["✨", "⭐️", "🔥", "🌙", "☀️", "🌱", "🧶", "🎯", "✅", "🕯️", "🎵", "🌊"]),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("Ya da bir emoji yaz", text: $custom)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: custom) { _, new in
                            if let first = new.first(where: Self.isEmoji) { pick(String(first)) }
                        }
                    ForEach(Self.groups.indices, id: \.self) { g in
                        Text(Self.groups[g].0).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                            ForEach(Self.groups[g].1, id: \.self) { e in
                                Button { pick(e) } label: {
                                    Text(e).font(.system(size: 30))
                                        .frame(maxWidth: .infinity, minHeight: 48)
                                        .background(e == selection ? Color.accentColor.opacity(0.18) : .clear,
                                                    in: .rect(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(Theme.gutter)
            }
            .navigationTitle("Simge")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Digits and "#" have the emoji property too, so require emoji presentation or a sequence.
    static func isEmoji(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first, s.properties.isEmoji else { return false }
        return s.properties.isEmojiPresentation || c.unicodeScalars.count > 1
    }

    private func pick(_ e: String) {
        selection = e
        dismiss()
    }
}
