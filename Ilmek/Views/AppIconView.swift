import SwiftUI

/// Alternate app icons from tools/make_icon.swift: asset `Icon-<color>-<detail>`, preview
/// image `IconPreview-<color>-<detail>`. Keep `colors` in sync with gen_knit_grid.py.
struct AppIconChoice: Hashable {
    enum Detail: String, CaseIterable { case detailed = "ayrintili", simple = "sade" }

    static let colors: [(key: String, name: LocalizedStringKey)] = [
        ("yesil", "Yeşil"), ("orman", "Orman"), ("mavi", "Mavi"), ("yesilmavi", "Yeşil ve mavi"),
        ("civit", "Çivit"), ("murdum", "Mürdüm"), ("gul", "Gül"), ("kiremit", "Kiremit"), ("safran", "Safran"),
    ]
    /// The icon in AppIcon.appiconset; choosing it clears the alternate icon.
    static let primary = AppIconChoice(color: "yesil", detail: .detailed)

    var color: String
    var detail: Detail

    var assetName: String { "Icon-\(color)-\(detail.rawValue)" }
    var preview: String { "IconPreview-\(color)-\(detail.rawValue)" }

    static var current: AppIconChoice {
        guard let name = UIApplication.shared.alternateIconName else { return primary }
        let parts = name.split(separator: "-").map(String.init)
        guard parts.count == 3, let d = Detail(rawValue: parts[2]),
              colors.contains(where: { $0.key == parts[1] }) else { return primary }
        return AppIconChoice(color: parts[1], detail: d)
    }
}

struct AppIconView: View {
    @State private var selected = AppIconChoice.current
    @State private var detail = AppIconChoice.current.detail
    @State private var failed = false

    private let grid = [GridItem(.adaptive(minimum: 88), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Picker("Ayrıntı", selection: $detail) {
                    Text("Ayrıntılı").tag(AppIconChoice.Detail.detailed)
                    Text("Sade").tag(AppIconChoice.Detail.simple)
                }
                .pickerStyle(.segmented)

                LazyVGrid(columns: grid, spacing: 20) {
                    ForEach(AppIconChoice.colors, id: \.key) { color in
                        let choice = AppIconChoice(color: color.key, detail: detail)
                        Button { apply(choice) } label: {
                            VStack(spacing: 8) {
                                AppIconPreview(choice: choice, size: 76)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 76 * 0.225, style: .continuous)
                                            .strokeBorder(Color.accentColor, lineWidth: selected == choice ? 3 : 0)
                                            .padding(-5)
                                    }
                                Text(color.name).font(.footnote)
                                    .foregroundStyle(selected == choice ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected == choice ? .isSelected : [])
                    }
                }
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background)
        .navigationTitle("Uygulama simgesi")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: selected)
        .alert("Simge değiştirilemedi", isPresented: $failed) {
            Button("Tamam", role: .cancel) {}
        }
    }

    private func apply(_ choice: AppIconChoice) {
        guard choice != selected, UIApplication.shared.supportsAlternateIcons else { return }
        let previous = selected
        selected = choice
        let name = choice == .primary ? nil : choice.assetName
        UIApplication.shared.setAlternateIconName(name) { error in
            guard error != nil else { return }
            Task { @MainActor in
                selected = previous
                failed = true
            }
        }
    }
}

struct AppIconPreview: View {
    let choice: AppIconChoice
    var size: CGFloat = 29

    var body: some View {
        Image(choice.preview)
            .resizable()
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}
