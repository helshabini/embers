import EmbersCore
import EmbersData
import SwiftUI

/// The "Scheduled" header that folds away what has not happened yet.
///
/// A register opening on a run of scheduled transfers shows almost nothing that has actually
/// happened, so this starts closed and remembers the choice across accounts. The count and total
/// stay on the header, which is the part worth seeing at a glance.
struct ScheduledHeader: View {
    let count: Int
    /// Only shown for a single account. Across all accounts both sides of every scheduled transfer
    /// are in the list, so they cancel and the total reads as a few pounds of nothing.
    var totalMinor: MinorUnits?
    @Binding var isExpanded: Bool

    @Environment(BudgetModel.self) private var budget

    var body: some View {
        Button {
            withAnimation(.snappy) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    // Points the way the text reads when folded, and down either way when open.
                    .flipsForRightToLeftLayoutDirection(true)
                Text("Scheduled")
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Flame.tintedFill, in: Capsule())
                    .foregroundStyle(Flame.deep)
                Spacer()
                if let totalMinor {
                    Text(budget.money(totalMinor))
                        .monospacedDigit()
                        .foregroundStyle(Flame.amountColor(totalMinor))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("scheduled-header")
        .accessibilityLabel("Scheduled, \(count)")
    }
}
