import SwiftUI
import IlmekKit

struct FriendsView: View {
    private var store = GroupStore.shared

    @State private var sheet: Sheet?
    @State private var afterProfile: Sheet?
    @State private var path: [GroupInfo] = []
    @AppStorage(Profile.nicknameKey) private var nickname = ""

    enum Sheet: Identifiable {
        case profile, create, join
        var id: Self { self }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .background(Theme.background)
                .navigationTitle("Arkadaşlar")
                .navigationDestination(for: GroupInfo.self) { GroupDetailView(code: $0.code) }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { sheet = .profile } label: {
                            Text(Profile.avatar).font(.title3)
                        }
                        .accessibilityLabel("Profil")
                    }
                    if store.availability == .available && !store.groups.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu("Ekle", systemImage: "plus") {
                                Button("Grup kur", systemImage: "person.3") { open(.create) }
                                Button("Koda katıl", systemImage: "number") { open(.join) }
                            }
                        }
                    }
                }
                .refreshable { await store.refresh() }
        }
        .sheet(item: $sheet, onDismiss: {
            if let next = afterProfile, Profile.isComplete { afterProfile = nil; sheet = next }
        }) { s in
            switch s {
            case .profile: ProfileSheet()
            case .create: CreateGroupSheet { path.append($0) }
            case .join: JoinGroupSheet { path.append($0) }
            }
        }
        .task { await store.refresh() }
    }

    /// Create/join need a nickname first.
    private func open(_ s: Sheet) {
        if Profile.isComplete { sheet = s } else { afterProfile = s; sheet = .profile }
    }

    @ViewBuilder private var content: some View {
        switch store.availability {
        case .checking where !store.groups.isEmpty:
            groupList
        case .unavailable where !store.groups.isEmpty:
            // Offline: keep showing the last known groups instead of an empty error.
            groupList
        case .checking:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noAccount:
            ContentUnavailableView {
                Label("iCloud gerekli", systemImage: "icloud.slash")
            } description: {
                Text("Arkadaşlarınla grup kurmak için Ayarlar'dan iCloud'a giriş yap. Alışkanlıkların bu cihazda çalışmaya devam eder.")
            }
        case .unavailable(let message):
            ContentUnavailableView("Gruplara şu an ulaşılamıyor", systemImage: "exclamationmark.icloud",
                                   description: Text(message))
        case .available:
            if store.groups.isEmpty { emptyState } else { groupList }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("🧶🧶").font(.system(size: 56)).padding(.top, 40)
                Text("Birlikte ör").font(.title.weight(.bold))
                Text("Bir grup kur ve kodu arkadaşlarınla paylaş. Kimin bugün kaç ilmek attığını görün, birbirinizi motive edin.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                VStack(spacing: 10) {
                    Button { open(.create) } label: {
                        Label("Grup kur", systemImage: "person.3.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { open(.join) } label: {
                        Label("Koda katıl", systemImage: "number").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .padding(.horizontal, 40)
                .padding(.top, 8)
                Text("Kayıt yok, şifre yok. Gizli alışkanlıkların arkadaşlarına hiç gösterilmez.")
                    .font(.footnote).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
            .padding(.horizontal, Theme.gutter)
        }
    }

    private var groupList: some View {
        ScrollView {
            VStack(spacing: 12) {
                if nickname.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Without a nickname nothing is published, so friends would see old numbers.
                    Button { sheet = .profile } label: {
                        Label("Arkadaşların ilerlemeni görebilsin diye bir takma ad gir.",
                              systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card(padding: 12)
                    }
                    .buttonStyle(.plain)
                }
                if case .unavailable(let message) = store.availability {
                    ErrorBanner(message: String(localized: "Çevrimdışı, son bilinen durum gösteriliyor. \(message)"))
                } else if let error = store.lastError {
                    ErrorBanner(message: error)
                }
                ForEach(store.groups) { g in
                    NavigationLink(value: g) { GroupCard(group: g) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Group card

private struct GroupCard: View {
    let group: GroupInfo
    private var store: GroupStore { .shared }

    var body: some View {
        let members = store.memberIDs(of: group)
        let statuses = members.compactMap { store.status(of: $0) }
        let today = DayKey.today()
        let doneToday = statuses.filter { $0.dayKey == today && $0.due > 0 && $0.done >= $0.due }.count

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(group.name).font(.headline)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            HStack(spacing: -8) {
                ForEach(statuses.prefix(6), id: \.userID) { s in
                    Text(s.avatar).font(.title3)
                        .frame(width: 36, height: 36)
                        .background(Theme.card, in: .circle)
                        .overlay(Circle().strokeBorder(s.dayKey == today && s.due > 0 && s.done >= s.due
                                                       ? Color.accentColor : .clear, lineWidth: 2))
                }
                if statuses.count > 6 {
                    Text("+\(statuses.count - 6)").font(.caption.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(Color(.tertiarySystemFill), in: .circle)
                }
            }
            Text("\(members.count) kişi · bugün \(doneToday) kişi tamamladı")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .card(padding: 16)
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "wifi.exclamationmark")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 12)
    }
}
