import SwiftUI

/// The palette — named after yarns, used for habits and for the daily stitch.
enum YarnColor: String, CaseIterable, Identifiable, Codable {
    case terracotta, saffron, olive, sage, teal, indigo, plum, rose, sand, charcoal

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .terracotta: Color(red: 0.78, green: 0.33, blue: 0.24)
        case .saffron: Color(red: 0.93, green: 0.65, blue: 0.20)
        case .olive: Color(red: 0.55, green: 0.56, blue: 0.24)
        case .sage: Color(red: 0.51, green: 0.65, blue: 0.53)
        case .teal: Color(red: 0.16, green: 0.53, blue: 0.56)
        case .indigo: Color(red: 0.25, green: 0.30, blue: 0.62)
        case .plum: Color(red: 0.49, green: 0.25, blue: 0.47)
        case .rose: Color(red: 0.86, green: 0.47, blue: 0.53)
        case .sand: Color(red: 0.80, green: 0.70, blue: 0.55)
        case .charcoal: Color(red: 0.27, green: 0.27, blue: 0.30)
        }
    }

    var name: LocalizedStringKey {
        switch self {
        case .terracotta: "Kiremit"
        case .saffron: "Safran"
        case .olive: "Zeytin"
        case .sage: "Adaçayı"
        case .teal: "Çini"
        case .indigo: "Çivit"
        case .plum: "Mürdüm"
        case .rose: "Gül"
        case .sand: "Kum"
        case .charcoal: "Kömür"
        }
    }
}
