import SwiftUI
import IlmekKit

struct GroupDetailView: View {
    let code: String
    private var store: GroupStore { .shared }
    @Environment(\.dismiss) private var dismiss

    @State private var inspecting: FriendStatus?
    @State private var showSettings = false
    @State private var confirmLeave = false
    @State private var kickTarget: FriendStatus?
    @State private var blockTarget: FriendStatus?
    @Environment(\.openURL) private var openURL
    @State private var error: String?

    var body: some View {
        if let group = store.groups.first(where: { $0.code == code }) {
            content(group)
        } else {
            ContentUnavailableView("Grup bulunamadı", systemImage: "person.3",
                                   description: Text("Grup kapatılmış ya da gruptan çıkmış olabilirsin."))
        }
    }

    private func content(_ group: GroupInfo) -> some View {
        let isOwner = group.ownerID == store.myID
        let today = DayKey.today()
        let members = store.memberIDs(of: group).map { id in (id, store.status(of: id)) }
            .sorted { a, b in
                // Me first, then by today's progress.
                if a.0 == store.myID { return true }
                if b.0 == store.myID { return false }
                return Self.fraction(a.1, today) > Self.fraction(b.1, today)
            }

        return ScrollView {
            VStack(spacing: 16) {
                CodeCard(group: group)
                if let error { ErrorBanner(message: error) }

                VStack(spacing: 10) {
                    ForEach(members, id: \.0) { id, status in
                        MemberRow(status: status, isMe: id == store.myID, isOwner: id == group.ownerID, today: today)
                            .contentShape(.rect)
                            .onTapGesture { if let status { inspecting = status } }
                            .contextMenu {
                                if id != store.myID, let status {
                                    Button("Bildir", systemImage: "exclamationmark.bubble") {
                                        if let url = AppLinks.report(status, groupCode: group.code) { openURL(url) }
                                    }
                                    Button("Engelle", systemImage: "hand.raised", role: .destructive) {
                                        blockTarget = status
                                    }
                                }
                                if isOwner && id != store.myID {
                                    Button("Gruptan çıkar", systemImage: "person.badge.minus", role: .destructive) {
                                        kickTarget = status ?? FriendStatus(userID: id, nickname: "?", avatar: "🙂",
                                                                            day: 0, done: 0, due: 0, perfectStreak: 0,
                                                                            habits: [], scarf: nil, updatedAt: .now)
                                    }
                                }
                            }
                    }
                }

                Button(isOwner ? "Grubu kapat" : "Gruptan çık", role: .destructive) { confirmLeave = true }
                    .padding(.top, 12)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 32)
        }
        .background(Theme.background)
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .toolbar {
            if isOwner {
                Button("Ayarlar", systemImage: "slider.horizontal.3") { showSettings = true }
            }
        }
        .sheet(item: $inspecting) { s in
            MemberDetailSheet(status: s, groupCode: group.code, isMe: s.userID == store.myID) { blockTarget = s }
        }
        .sheet(isPresented: $showSettings) { GroupSettingsSheet(group: group) }
        .confirmationDialog(isOwner ? "Grup herkes için kapanacak." : "Gruptan çıkılsın mı?",
                            isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(isOwner ? "Grubu kapat" : "Çık", role: .destructive) {
                Task {
                    do { try await store.leave(group); dismiss() }
                    catch { self.error = GroupStore.message(for: error) }
                }
            }
        }
        .confirmationDialog("\(blockTarget?.nickname ?? "") engellensin mi?",
                            isPresented: Binding(get: { blockTarget != nil }, set: { if !$0 { blockTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Engelle", role: .destructive) {
                if let target = blockTarget { withAnimation { store.block(target) } }
            }
        } message: {
            Text("Bu kişiyi artık hiçbir grupta görmezsin ve onun bildirimleri gelmez. Profil ekranından engeli kaldırabilirsin.")
        }
        .confirmationDialog("\(kickTarget?.nickname ?? "") gruptan çıkarılsın mı?",
                            isPresented: Binding(get: { kickTarget != nil }, set: { if !$0 { kickTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Çıkar", role: .destructive) {
                guard let target = kickTarget else { return }
                Task {
                    do { try await store.update(group, ban: target.userID) }
                    catch { self.error = GroupStore.message(for: error) }
                }
            }
        }
    }

    static func fraction(_ s: FriendStatus?, _ today: DayKey) -> Double {
        guard let s, s.dayKey == today, s.due > 0 else { return -1 }
        return Double(s.done) / Double(s.due)
    }
}

extension FriendStatus: Identifiable { var id: String { userID } }

// MARK: - Code card

private struct CodeCard: View {
    let group: GroupInfo
    @State private var copied = false

    var body: some View {
        VStack(spacing: 10) {
            Text("Davet kodu").font(.subheadline).foregroundStyle(.secondary)
            Text(group.displayCode)
                .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                .textSelection(.enabled)
                .accessibilityLabel(group.code.map(String.init).joined(separator: " "))
            HStack(spacing: 10) {
                Button(copied ? "Kopyalandı" : "Kopyala", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = group.displayCode
                    copied = true
                }
                .buttonStyle(.bordered)
                ShareLink(item: String(localized: "İlmek'te grubuma katıl 🧶 Kod: \(group.displayCode)")) {
                    Label("Paylaş", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .sensoryFeedback(.success, trigger: copied)
            if group.memberLimit > 0 {
                Text("En fazla \(group.memberLimit) kişi").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .card(padding: 18)
    }
}

// MARK: - Member row

private struct MemberRow: View {
    let status: FriendStatus?
    let isMe: Bool
    let isOwner: Bool
    let today: DayKey
    @AppStorage(Profile.knitEnabledKey) private var knitOn = false

    var body: some View {
        HStack(spacing: 14) {
            Text(status?.avatar ?? "🙂").font(.title2)
                .frame(width: 46, height: 46)
                .background(Color(.tertiarySystemFill), in: .circle)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(status?.nickname.isEmpty == false ? status!.nickname : String(localized: "Yeni üye"))
                        .font(.body.weight(.semibold))
                    if isMe { Text("sen").font(.caption).foregroundStyle(.secondary) }
                    if isOwner { Image(systemName: "crown.fill").font(.caption2).foregroundStyle(.yellow) }
                }
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                if let p = status?.scarfPayload { MiniScarf(payload: p, colored: knitOn) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let s = status, s.dayKey == today, s.due > 0 {
                ZStack {
                    ProgressRing(progress: s.done, target: s.due, color: .accentColor, lineWidth: 4)
                    if s.done >= s.due {
                        Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(Color.accentColor)
                    } else {
                        Text("\(s.done)/\(s.due)").font(.caption2.weight(.semibold).monospacedDigit())
                    }
                }
                .frame(width: 42, height: 42)
            }
        }
        .card()
    }

    private var subtitle: String {
        guard let s = status else { return String(localized: "Henüz bir şey paylaşmadı") }
        let streak = s.perfectStreak > 0 ? "🔥 \(s.perfectStreak) · " : ""
        if s.dayKey == today {
            if s.due == 0 { return streak + String(localized: "Bugün dinlenme günü") }
            return streak + String(localized: "Bugün \(s.done)/\(s.due)")
        }
        if let d = s.dayKey, d == today.adding(days: -1) {
            return streak + String(localized: "Bugün henüz açmadı · dün \(s.done)/\(s.due)")
        }
        return streak + String(localized: "Son görülme \(s.updatedAt.formatted(.relative(presentation: .named)))")
    }
}

/// Last two weeks of a friend's scarf as a tiny strip.
struct MiniScarf: View {
    let payload: ScarfPayload
    /// Yarn colours (knit mode, and the friend shares them) or the app accent.
    var colored = false

    var body: some View {
        let days = payload.days.suffix(14)
        HStack(spacing: 2) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, e in
                let yarn = YarnColor.allCases.indices.contains(Int(e.color)) ? YarnColor.allCases[Int(e.color)].color : nil
                let c = colored ? (yarn ?? Color.accentColor) : Color.accentColor
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(e.fraction == 0 ? Color(.systemFill) : c.opacity(0.25 + 0.75 * Double(e.fraction) / 255))
                    .frame(width: 9, height: 12)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Member detail

private struct MemberDetailSheet: View {
    let status: FriendStatus
    var groupCode: String? = nil
    var isMe = false
    var onBlock: (() -> Void)? = nil
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Profile.knitEnabledKey) private var knitOn = false

    var body: some View {
        let isToday = status.dayKey == DayKey.today()
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Text(status.avatar).font(.system(size: 56))
                        Text(status.nickname).font(.title2.weight(.bold))
                        if status.perfectStreak > 0 {
                            Text("🔥 \(status.perfectStreak) günlük tam seri").font(.subheadline).foregroundStyle(.orange)
                        }
                    }
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(isToday ? "Bugün" : "Son paylaşılan gün").font(.headline)
                        if status.habits.isEmpty {
                            Text("Bugün için paylaşılan alışkanlık yok.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(status.habits, id: \.self) { h in
                            let color = (YarnColor(rawValue: h.color) ?? .terracotta).color
                            HStack(spacing: 12) {
                                HabitBadge(emoji: h.emoji, color: color, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.name).font(.subheadline.weight(.semibold))
                                    if h.streak > 0 {
                                        Text("🔥 \(h.streak)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if h.isDone {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(color).font(.title3)
                                } else {
                                    ProgressRing(progress: h.progress, target: h.target, color: color, lineWidth: 3)
                                        .frame(width: 24, height: 24)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(padding: 16)

                    if let p = status.scarfPayload {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("İlerlemesi").font(.headline)
                            Heatmap(start: p.start, end: p.last, today: DayKey.today(), color: .accentColor,
                                    selected: .constant(nil)) { day in
                                p.entry(on: day).map { HeatCell.value(Double($0.fraction) / 255) } ?? .none
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(padding: 16)
                    }

                    if knitOn {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Atkısı").font(.headline)
                        if let p = status.scarfPayload, p.hasColors {
                            ScarfCanvas(model: FriendScarf(p), highlight: nil, onTap: nil)
                        } else {
                            Text("Atkısını gizli tutuyor.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(padding: 16)
                    }

                    if !isMe {
                        HStack(spacing: 12) {
                            Button("Bildir", systemImage: "exclamationmark.bubble") {
                                if let url = AppLinks.report(status, groupCode: groupCode) { openURL(url) }
                            }
                            Button("Engelle", systemImage: "hand.raised", role: .destructive) {
                                dismiss()
                                onBlock?()
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.subheadline)
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .toolbar { Button("Kapat") { dismiss() } }
        }
        .presentationDragIndicator(.visible)
    }
}
