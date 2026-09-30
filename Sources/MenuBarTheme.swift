import Foundation

enum MenuBarTheme: String, CaseIterable, Identifiable {
    case ring
    case duoDuoCat = "duoduocat"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ring: return L("圆环", "Ring")
        case .duoDuoCat: return L("多多猫", "DuoDuoCat")
        }
    }
}
