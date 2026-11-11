import SwiftUI
import SwiftData
import CloudKit
import IlmekKit

struct OnboardingView: View {
    let onFinish: () -> Void

    @Environment(\.modelContext) private var context
    @Query private var existing: [Habit]
    @State private var page = 0
    @State private var iCloud: Bool?
    @State private var picked: Set<String> = []

    private let pages = 4

    struct Starter: Identifiable {
        let id: String
        let name: String
        let emoji: String
        let color: YarnColor
        var schedule: Schedule = .daily
        var isMedication = false
    }

    private var starters: [Starter] {[
        Starter(id: "water", name: String(localized: "Su iç"), emoji: "💧", color: .teal, schedule: Schedule(timesPerDay: 8)),
        Starter(id: "read", name: String(localized: "Kitap oku"), emoji: "📚", color: .indigo),
        Starter(id: "walk", name: String(localized: "Yürüyüş"), emoji: "🚶", color: .olive),
        Starter(id: "sleep", name: String(localized: "Erken yat"), emoji: "😴", color: .plum),
        Starter(id: "sport", name: String(localized: "Spor"), emoji: "🏋️", color: .terracotta,
                schedule: Schedule(pattern: .timesPerWeek(3))),
        Starter(id: "vitamin", name: String(localized: "Vitamin"), emoji: "💊", color: .rose, isMedication: true),
    ]}

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                flexible.tag(1)
                safe.tag(2)
                start.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.snappy, value: page)

            HStack(spacing: 6) {
                ForEach(0..<pages, id: \.self) { i in
                    Capsule().fill(i == page ? Color.accentColor : Color(.tertiarySystemFill))
                        .frame(width: i == page ? 22 : 7, height: 7)
                }
            }
            .animation(.snappy, value: page)
            .padding(.bottom, 20)

            Button {
                if page < pages - 1 { page += 1 } else { finish() }
            } label: {
                Text(page < pages - 1 ? "Devam" : (picked.isEmpty || !existing.isEmpty ? "Başla" : "\(picked.count) alışkanlıkla başla"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .sensoryFeedback(.impact(weight: .light), trigger: page)
        }
        .background(Theme.background)
        .task { await checkICloud() }
    }

    // MARK: Pages

    private func pageLayout<Content: View>(_ art: String, _ title: LocalizedStringKey, _ body: LocalizedStringKey,
                                           @ViewBuilder extra: () -> Content = { EmptyView() }) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 40)
                Text(art).font(.system(size: 80))
                Text(title).font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
                Text(body).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                extra()
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var welcome: some View {
        pageLayout("🧶", "Her gün bir ilmek",
                   "Alışkanlıklarını işaretle, serini büyüt. Takvimde her günün nasıl geçtiğini gör. İstersen ayarlardan Örgü modunu aç; her gün atkına bir ilmek olarak eklensin.")
    }

    private var flexible: some View {
        pageLayout("🗓️", "İstediğin sıklıkta",
                   "Her gün, haftanın belirli günleri, haftada üç kez, ayda bir… İlaçlar için saatli hatırlatmalar. Sınırsız alışkanlık, tamamen ücretsiz.")
    }

    private var safe: some View {
        pageLayout("☁️", "Serin kaybolmaz",
                   "Verilerin kendi iCloud'unda saklanır. App'i silsen de, yeni telefona geçsen de alışkanlıkların ve serin geri gelir. Hesap yok, şifre yok.") {
            Group {
                switch iCloud {
                case .some(true):
                    Label("iCloud açık, yedekleme çalışıyor", systemImage: "checkmark.icloud.fill")
                        .foregroundStyle(.green)
                case .some(false):
                    VStack(spacing: 8) {
                        Label("iCloud kapalı: veriler sadece bu cihazda kalır", systemImage: "exclamationmark.icloud.fill")
                            .foregroundStyle(.orange)
                        Text("Ayarlar › [adın] › iCloud'dan giriş yapabilirsin.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                case .none:
                    ProgressView()
                }
            }
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.top, 8)
        }
    }

    @ViewBuilder private var start: some View {
        if !existing.isEmpty {
            pageLayout("🎉", "Tekrar hoş geldin",
                       "\(existing.count) alışkanlığın iCloud'dan geri geldi. Kaldığın yerden devam et.")
        } else {
            starterPage
        }
    }

    private var starterPage: some View {
        pageLayout("✨", "Nereden başlayalım?",
                   "Birkaç tane seç ya da boş başla. Sonra istediğin gibi düzenleyebilirsin.") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(starters) { s in
                    let on = picked.contains(s.id)
                    Button {
                        if on { picked.remove(s.id) } else { picked.insert(s.id) }
                    } label: {
                        HStack(spacing: 10) {
                            Text(s.emoji).font(.title3)
                            Text(s.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(on ? s.color.color : Color.secondary)
                        }
                        .padding(12)
                        .background(on ? s.color.color.opacity(0.14) : Theme.card,
                                    in: .rect(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .sensoryFeedback(.selection, trigger: picked)
            .padding(.top, 8)
        }
    }

    // MARK: Actions

    private func checkICloud() async {
        let status = try? await CKContainer(identifier: Store.cloudContainer).accountStatus()
        iCloud = status == .available
    }

    private func finish() {
        guard existing.isEmpty else { onFinish(); return }
        var created: [Habit] = []
        for (i, s) in starters.filter({ picked.contains($0.id) }).enumerated() {
            let h = Habit(name: s.name, emoji: s.emoji, color: s.color, schedule: s.schedule,
                          isMedication: s.isMedication)
            h.sortOrder = Double(i)
            context.insert(h)
            created.append(h)
        }
        if !created.isEmpty {
            context.saveQuietly()
            // iCloud may still be bringing back older habits; drop these if they turn out to be twins.
            StarterDedupe.remember(created)
            StarterDedupe.start(container: context.container)
        }
        onFinish()
    }
}
