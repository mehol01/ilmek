import SwiftUI
import IlmekKit

// MARK: - Profile

struct ProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Profile.nicknameKey) private var nickname = ""
    @AppStorage(Profile.avatarKey) private var avatar = "🙂"
    @AppStorage(Profile.shareScarfKey) private var shareScarf = true
    @AppStorage(Profile.notifyFriendsKey) private var notifyFriends = true
    @AppStorage(Profile.knitEnabledKey) private var knitOn = false
    @AppStorage(Profile.shareHistoryKey) private var shareHistory = true

    @State private var draftName = ""
    @State private var confirmDelete = false
    @State private var error: String?
    @FocusState private var focused: Bool

    static let avatars = ["🙂", "😎", "🤓", "🥳", "😺", "🐶", "🦊", "🐻", "🐼", "🐨", "🐸", "🦉",
                          "🐢", "🐙", "🦄", "🐝", "🌻", "🌵", "🍄", "⭐️", "🌙", "🔥", "🧶", "🎧"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        Text(avatar).font(.system(size: 64))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
                            ForEach(Self.avatars, id: \.self) { a in
                                Button { avatar = a } label: {
                                    Text(a).font(.title2)
                                        .frame(maxWidth: .infinity, minHeight: 38)
                                        .background(a == avatar ? Color.accentColor.opacity(0.18) : .clear,
                                                    in: .rect(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .sensoryFeedback(.selection, trigger: avatar)
                    }
                    .frame(maxWidth: .infinity)
                    TextField("Takma ad", text: $draftName)
                        .focused($focused)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                } footer: {
                    Text("Arkadaşların seni bu adla görür. Hesap ya da şifre yok; kimliğin iCloud'dan gelir.")
                }

                Section {
                    Toggle("İlerleme geçmişimi arkadaşlarım görsün", isOn: $shareHistory)
                    if knitOn && shareHistory { Toggle("Atkımı arkadaşlarım görsün", isOn: $shareScarf) }
                    Toggle("Arkadaşlarım günü bitirince haber ver", isOn: $notifyFriends)
                } footer: {
                    Text("İlerleme geçmişi, arkadaşlarının seni takvim üzerinde görmesini sağlar: hangi gün ne kadarını tamamladığın. Alışkanlıklarının adları bundan görünmez.")
                }
                .onChange(of: shareHistory) { Task { await StatusPublisher.shared.publish(force: true) } }
                .onChange(of: shareScarf) { Task { await StatusPublisher.shared.publish(force: true) } }

                if !GroupStore.shared.blocked.isEmpty {
                    Section {
                        ForEach(GroupStore.shared.blocked.sorted { $0.value < $1.value }, id: \.key) { id, name in
                            HStack {
                                Text(name.isEmpty ? "?" : name)
                                Spacer()
                                Button("Engeli kaldır") { withAnimation { GroupStore.shared.unblock(id) } }
                                    .buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text("Engellenenler")
                    } footer: {
                        Text("Engellediğin kişileri hiçbir grupta görmezsin ve bildirimleri gelmez. Bu yalnızca bu telefonda geçerli.")
                    }
                }

                if !GroupStore.shared.groups.isEmpty || GroupStore.shared.status(of: GroupStore.shared.myID ?? "") != nil {
                    Section {
                        Button("Gruplardan çık ve paylaştıklarımı sil", role: .destructive) { confirmDelete = true }
                    } footer: {
                        if let error { Text(error).foregroundStyle(.red) }
                        else { Text("Alışkanlıkların ve geçmişin silinmez; sadece arkadaşlarla paylaşılan veriler silinir.") }
                    }
                }
            }
            .navigationTitle("Profil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { save() }
                        .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                draftName = nickname
                if nickname.isEmpty { focused = true }
            }
            .confirmationDialog("Tüm gruplardan çıkılsın ve paylaştıkların silinsin mi?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Sil", role: .destructive) {
                    Task {
                        do { try await GroupStore.shared.deleteAllMyData(); dismiss() }
                        catch { self.error = GroupStore.message(for: error) }
                    }
                }
            }
        }
    }

    private func save() {
        nickname = String(draftName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        Task {
            await StatusPublisher.shared.publish(force: true)
            await GroupStore.shared.updateSubscriptions()
        }
        dismiss()
    }
}

// MARK: - Create

struct CreateGroupSheet: View {
    let onCreated: (GroupInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var limited = false
    @State private var limit = 10
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Grup adı (örn. Sabah kulübü)", text: $name)
                }
                Section {
                    Toggle("Üye sınırı koy", isOn: $limited.animation())
                    if limited {
                        Stepper("En fazla \(limit) kişi", value: $limit, in: 2...100)
                    }
                } footer: {
                    Text("Sınırı sonra grup ayarlarından değiştirebilirsin.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Grup kur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Kur", action: create) }
                }
            }
            .interactiveDismissDisabled(busy)
        }
    }

    private func create() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let g = try await GroupStore.shared.createGroup(name: name, memberLimit: limited ? limit : 0)
                dismiss()
                onCreated(g)
            } catch {
                self.error = GroupStore.message(for: error)
            }
        }
    }
}

// MARK: - Join

struct JoinGroupSheet: View {
    let onJoined: (GroupInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Arkadaşının paylaştığı 8 karakterlik kodu gir.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                TextField("K7QF-29XM", text: $code)
                    .font(.system(.title, design: .monospaced).weight(.bold))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.join)
                    .onSubmit(join)
                    .onChange(of: code) { _, new in
                        let cleaned = new.uppercased().filter { GroupCode.alphabet.contains($0) }.prefix(8)
                        let formatted = cleaned.count > 4 ? "\(cleaned.prefix(4))-\(cleaned.dropFirst(4))" : String(cleaned)
                        if formatted != new { code = formatted }
                    }
                    .padding()
                    .background(Theme.card, in: .rect(cornerRadius: 16, style: .continuous))

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                Button {
                    if let s = UIPasteboard.general.string { code = s }
                } label: {
                    Label("Yapıştır", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(Theme.gutter)
            .background(Theme.background)
            .navigationTitle("Koda katıl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Katıl", action: join).disabled(GroupCode.normalize(code) == nil)
                    }
                }
            }
            .onAppear { focused = true }
            .interactiveDismissDisabled(busy)
        }
    }

    private func join() {
        guard GroupCode.normalize(code) != nil, !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let g = try await GroupStore.shared.join(code: code)
                dismiss()
                onJoined(g)
            } catch {
                self.error = GroupStore.message(for: error)
            }
        }
    }
}

// MARK: - Group settings (owner)

struct GroupSettingsSheet: View {
    let group: GroupInfo
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var limited = false
    @State private var limit = 10
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Ad") { TextField("Grup adı", text: $name) }
                Section {
                    Toggle("Üye sınırı", isOn: $limited.animation())
                    if limited { Stepper("En fazla \(limit) kişi", value: $limit, in: 2...100) }
                } footer: {
                    Text("Sınır yeni katılımlar için geçerli; mevcut üyeler çıkarılmaz.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Grup ayarları")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Kaydet", action: save) }
                }
            }
            .onAppear {
                name = group.name
                limited = group.memberLimit > 0
                limit = group.memberLimit > 0 ? min(max(group.memberLimit, 2), 100) : 10
            }
        }
    }

    private func save() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await GroupStore.shared.update(group, name: name, memberLimit: limited ? limit : 0)
                dismiss()
            } catch {
                self.error = GroupStore.message(for: error)
            }
        }
    }
}
