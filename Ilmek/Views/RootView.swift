import SwiftUI
import SwiftData
import IlmekKit

struct RootView: View {
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage(Profile.knitEnabledKey) private var knitOn = false
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.state == .memory {
            // Showing empty tabs here would look like lost data, and anything added would vanish.
            ContentUnavailableView {
                Label("Verilerine şu an ulaşılamıyor", systemImage: "lock.icloud")
            } description: {
                Text("Alışkanlıkların güvende. Telefonun kilidini açtıktan sonra tekrar dene.")
            } actions: {
                Button("Tekrar dene") { store.retryIfNeeded() }
                    .buttonStyle(.borderedProminent)
            }
            .preferredColorScheme(Appearance(rawValue: appearance)?.scheme)
        } else {
            tabs
                .preferredColorScheme(Appearance(rawValue: appearance)?.scheme)
                .fullScreenCover(isPresented: .constant(!onboarded)) {
                    OnboardingView { onboarded = true }
                }
        }
    }

    private var tabs: some View {
        TabView {
            Tab("Bugün", systemImage: "checkmark.circle") {
                TodayView()
            }
            Tab(knitOn ? "Örgü" : "İstatistik", systemImage: knitOn ? "square.grid.3x3.fill" : "chart.bar.fill") {
                KnitView()
            }
            Tab("Arkadaşlar", systemImage: "person.2") {
                FriendsView()
            }
        }
    }
}

struct PlaceholderView: View {
    let title: LocalizedStringKey
    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: "hammer")
                .navigationTitle(title)
        }
    }
}
