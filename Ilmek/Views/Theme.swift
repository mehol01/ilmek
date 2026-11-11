import SwiftUI

enum Theme {
    static let cardRadius: CGFloat = 22
    static let gutter: CGFloat = 16
    static let background = Color(.systemGroupedBackground)
    static let card = Color(.secondarySystemGroupedBackground)
}

extension View {
    func card(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// Emoji in a soft tinted circle — the habit's "badge".
struct HabitBadge: View {
    let emoji: String
    let color: Color
    var size: CGFloat = 44

    var body: some View {
        Text(emoji)
            .font(.system(size: size * 0.5))
            .frame(width: size, height: size)
            .background(color.opacity(0.16), in: .circle)
    }
}

/// Ring split into `target` segments (or a smooth ring above 12).
struct ProgressRing: View {
    let progress: Int
    let target: Int
    let color: Color
    var lineWidth: CGFloat = 4

    var body: some View {
        let segments = target > 1 && target <= 12 ? target : 1
        let gap = segments > 1 ? 0.035 : 0
        let fraction = min(1, Double(progress) / Double(max(target, 1)))
        ZStack {
            ForEach(0..<segments, id: \.self) { i in
                let lo = Double(i) / Double(segments) + gap / 2
                let hi = Double(i + 1) / Double(segments) - gap / 2
                Circle().trim(from: lo, to: hi)
                    .stroke(color.opacity(0.18), style: .init(lineWidth: lineWidth, lineCap: .round))
                let filledHi = segments == 1 ? fraction : (i < progress ? hi : lo)
                if filledHi > lo {
                    Circle().trim(from: segments == 1 ? 0 : lo, to: filledHi)
                        .stroke(color, style: .init(lineWidth: lineWidth, lineCap: .round))
                }
            }
        }
        .rotationEffect(.degrees(-90))
    }
}
