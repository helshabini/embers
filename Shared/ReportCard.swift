import EmbersCore
import SwiftUI

/// One report, on its own card: a small titled heading, then whatever the report has to say.
///
/// The cards carry the page rather than a list does, because each report wants a different shape —
/// a headline figure, a bar, a legend — and a grouped list forces them all into rows.
struct ReportCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Flame.ember)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Flame.cardBackground)
        )
    }
}

/// The figure a card is really about.
struct ReportHeadline: View {
    let caption: String?
    let value: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let caption {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(tint ?? .primary)
        }
    }
}

/// An axis label short enough to sit beside a chart.
///
/// A y-axis reading "600,000" crowds the plot and a truncated "50,0…" says nothing, so thousands and
/// millions are named rather than spelled out — in the reader's language: "40K", "40 Tsd.", "4万".
func compactAxisAmount(_ major: Double, symbol: String) -> String {
    let magnitude = abs(major)
    guard magnitude >= 1 else { return "\(symbol)\(0.formatted(.number.locale(.display)))" }
    let sign = major < 0 ? "-" : ""
    // One decimal while the leading figure is a single digit — "4.5K", "1.2M" — none after.
    let digits = (1_000..<10_000).contains(magnitude) || magnitude >= 1_000_000 ? 1 : 0
    let number = magnitude.formatted(
        .number.notation(.compactName).precision(.fractionLength(0...digits))
    )
    return "\(sign)\(symbol)\(number)"
}

/// A single bar split into its parts, each one a share of the whole.
///
/// The segments are separated by a gap rather than a border, so they read as parts of one bar at any
/// size. A share too small to see still gets a sliver: leaving it out would make the bar lie about
/// adding up.
struct ShareBar: View {
    /// Each part's size and colour, largest first.
    let parts: [(value: Double, color: Color)]

    private let spacing: CGFloat = 2
    private let height: CGFloat = 26

    var body: some View {
        GeometryReader { proxy in
            let total = parts.reduce(0) { $0 + max($1.value, 0) }
            let gaps = spacing * CGFloat(max(parts.count - 1, 0))
            let usable = max(proxy.size.width - gaps, 1)
            HStack(spacing: spacing) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(part.color)
                        .frame(width: max(usable * width(of: part.value, total: total), 3))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func width(of value: Double, total: Double) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(max(value, 0) / total)
    }
}

/// A colour, a name, and an amount: the legend and the table in one, which is what lets a segment
/// too pale to carry on its own still be identified.
struct ShareRow: View {
    let color: Color
    let name: String
    let detail: String?
    let amount: String

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 4, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(amount)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
