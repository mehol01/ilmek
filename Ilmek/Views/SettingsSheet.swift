import SwiftUI
import SwiftData
import CloudKit
import UserNotifications
import IlmekKit

enum Appearance: Int, CaseIterable {
    case system, light, dark
    static let key = "appearance"
    var scheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Profile.knitEnabledKey) private var knitOn = false
    @Environment(\.modelContext) private var context
    @Query private var habits: [Habit]
    @State private var vacationEnd = DayKey.today().adding(days: 7).startDate(in: .current)
    @State private var includeMeds = false
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue
    @State private var iconChoice = AppIconChoice.current
    @State private var notifications: UNAuthorizationStatus?
    @State private var iCloud: CKAccountStatus?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ManageHabitsView()
                    } label: {
                        Label("Alışkanlıklarım", systemImage: "list.bullet")
                    }
                } footer: {
                    Text("Sırala, arşivdekileri geri al.")
                }

                vacationSection

                Section("Tema") {
                    Picker("Tema", selection: $appearance) {
                        Text("Sistem").tag(Appearance.system.rawValue)
                        Text("Açık").tag(Appearance.light.rawValue)
                        Text("Koyu").tag(Appearance.dark.rawValue)
                    }
                    .pickerStyle(.segmented)
                    if UIApplication.shared.supportsAlternateIcons {
                        NavigationLink {
                            AppIconView()
                        } label: {
                            HStack(spacing: 12) {
                                AppIconPreview(choice: iconChoice)
                                Text("Uygulama simgesi")
                            }
                        }
                    }
                }
                .onAppear { iconChoice = .current }

                statusSection

                Section {
                    Toggle(isOn: $knitOn.animation()) {
                        Label("Örgü modu", systemImage: "square.grid.3x3.fill")
                    }
                } footer: {
                    Text("Her tamamladığın gün atkına bir ilmek olarak eklenir; günün ipliğini sen seçersin. Kapalıyken de atkın arka planda örülmeye devam eder.")
                }

                Section {
                    Link(destination: AppLinks.feedback) {
                        Label("Geri bildirim gönder", systemImage: "envelope")
                    }
                    Link(destination: AppLinks.privacy) {
                        Label("Gizlilik politikası", systemImage: "hand.raised")
                    }
                } footer: {
                    Text(verbatim: "İlmek \(Self.version)")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } }
            }
            .task { await loadStatus() }
            .onChange(of: scenePhase) { _, p in if p == .active { Task { await loadStatus() } } }
            .onChange(of: knitOn) {
                // Friends see the scarf only while knit mode is on.
                Task { await StatusPublisher.shared.publish(force: true) }
            }
        }
    }

    // MARK: Status

    @ViewBuilder private var statusSection: some View {
        Section("Durum") {
            // Notifications
            switch notifications {
            case .denied?:
                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    statusRow("Bildirimler", "bell.slash.fill", .orange,
                              "Kapalı: hatırlatmalar gelmez. Açmak için dokun.")
                }
                .buttonStyle(.plain)
            case .notDetermined?:
                statusRow("Bildirimler", "bell", .secondary, "Henüz izin verilmedi; hatırlatma eklerken sorulur.")
            case nil:
                statusRow("Bildirimler", "bell", .secondary, "…")
            default:
                statusRow("Bildirimler", "bell.fill", .green, "İzin verildi")
            }
            // iCloud
            switch iCloud {
            case .available? where store.state == .localOnly:
                statusRow("iCloud", "exclamationmark.icloud.fill", .orange,
                          "Eşitleme başlatılamadı: veriler şimdilik sadece bu cihazda. Uygulamayı kapatıp yeniden aç.")
            case .available?:
                statusRow("iCloud", "checkmark.icloud.fill", .green, "Açık: alışkanlıkların ve serin yedekleniyor.")
            case nil:
                statusRow("iCloud", "icloud", .secondary, "…")
            default:
                statusRow("iCloud", "exclamationmark.icloud.fill", .orange,
                          "Kapalı: veriler sadece bu cihazda. Ayarlar › [adın] › iCloud'dan aç.")
            }
        }
    }

    private func statusRow(_ title: LocalizedStringKey, _ symbol: String, _ tint: Color,
                           _ detail: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }

    private func loadStatus() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        iCloud = try? await CKContainer(identifier: Store.cloudContainer).accountStatus()
        if iCloud == nil { iCloud = .couldNotDetermine }
    }

    // MARK: Vacation

    @ViewBuilder private var vacationSection: some View {
        let today = DayKey.today()
        Section {
            if let end = Vacation.until(habits, today: today) {
                LabeledContent("Bitiş") {
                    Text(end.startDate(in: .current).formatted(.dateTime.day().month(.wide)))
                }
                Button("Tatili bitir", systemImage: "play.fill") {
                    withAnimation { Vacation.end(habits: habits, in: context) }
                }
            } else {
                DatePicker("Bitiş", selection: $vacationEnd,
                           in: today.adding(days: 1).startDate(in: .current)...today.adding(days: 365).startDate(in: .current),
                           displayedComponents: .date)
                Toggle("İlaçları da duraklat", isOn: $includeMeds)
                Button("Tatile başla", systemImage: "beach.umbrella") {
                    withAnimation {
                        Vacation.start(through: DayKey(vacationEnd, calendar: .current),
                                       includeMedications: includeMeds, habits: habits, in: context)
                    }
                }
                .disabled(habits.allSatisfy { $0.archivedAt != nil })
            }
        } header: {
            Text("Tatil modu")
        } footer: {
            Text("Bütün alışkanlıkların bitiş gününe kadar duraklar: serin bozulmaz, hatırlatma gelmez. Tek bir alışkanlığı da düzenleme ekranından duraklatabilirsin.")
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }
}
