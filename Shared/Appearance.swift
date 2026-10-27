import SwiftUI

/// Whether the app follows the phone's appearance or is pinned to one.
///
/// Following the system is the default and the right answer for nearly everyone. The override exists
/// because a budget is often opened in bed, where a white screen is the whole complaint.
enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    var symbol: String {
        switch self {
        #if os(macOS)
        case .system: "desktopcomputer"
        #else
        case .system: "iphone"
        #endif
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// `nil` hands the decision back to iOS.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension View {
    /// Applies the stored appearance. The whole window has to carry it, so sheets and pushed screens
    /// inherit it too.
    func appearanceApplied(_ appearance: Appearance) -> some View {
        preferredColorScheme(appearance.colorScheme)
    }
}
