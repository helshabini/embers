import EmbersCore
import SwiftUI

extension CategoryStatus {
    /// YNAB's colours. Red: cash overspent, and next month pays for it unless covered. Orange: card
    /// spending nothing covered, now debt; or less than what is still to come this month. Green:
    /// enough. Grey: nothing there and nothing needed.
    var color: Color {
        switch self {
        case .overspent: Flame.outflow
        case .creditOverspent, .underfunded: Flame.glow
        case .funded: Flame.inflow
        case .empty: .secondary
        }
    }
}
