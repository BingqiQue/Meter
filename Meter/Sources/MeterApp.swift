import SwiftUI

extension Color {
    static let meterAmber = Color(red: 0.72, green: 0.43, blue: 0.10)
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
    var scheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
}

@main
struct MeterApp: App {
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    var body: some Scene {
        WindowGroup { MeterView().preferredColorScheme(appearance.scheme).tint(.meterAmber) }
    }
}
