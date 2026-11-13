import Charts
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

extension MinorUnits {
    /// Charts plot in major units; the ledger keeps minor ones. By the currency's own digits: a
    /// yen plan has none, and dividing by a hundred drew it a hundredth of its size.
    func major(_ currency: Currency) -> Double {
        Double(self) / pow(10, Double(currency.minorUnitDigits))
    }
}

/// The axes every report's charts share.
struct ReportAxes {
    let currency: Currency
    /// How many months the chart spans, which decides how far apart the date labels sit.
    let months: Int

    /// Thousands named rather than spelled out, on the right where they do not push the plot over.
    var amount: some AxisContent {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine()
            AxisValueLabel {
                if let major = value.as(Double.self) {
                    Text(compactAxisAmount(major, symbol: currency.symbol))
                }
            }
        }
    }

    /// Dates along the bottom, at a spacing the width can actually hold.
    var month: some AxisContent {
        AxisMarks(values: .stride(by: .month, count: stride)) { value in
            AxisGridLine()
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Text(date.formatted(format))
                }
            }
        }
    }

    /// How many months between labels.
    ///
    /// A fixed ceiling of six months meant seven years of history drew fourteen labels into the space
    /// for six, which ran together as "AugFebAugFeb". The gap is chosen from the span instead, aiming
    /// for about six labels, and snapped to a period a reader recognises rather than an arbitrary
    /// number of months.
    private var stride: Int {
        guard months > 6 else { return 1 }
        let wanted = Int((Double(months) / 6).rounded(.up))
        return [1, 2, 3, 6, 12, 24, 60].first { $0 >= wanted } ?? 120
    }

    /// Months while the gap is short enough for them to mean something; years once it is not.
    private var format: Date.FormatStyle {
        switch stride {
        case ..<6: .dateTime.month(.abbreviated).locale(.display)
        case ..<12: .dateTime.month(.abbreviated).year(.twoDigits).locale(.display)
        default: .dateTime.year().locale(.display)
        }
    }

    /// Zero to a little above the largest value, dipping below only if something is actually negative.
    ///
    /// Left to itself the axis rounded a single small negative month out to −$50K and spent half the
    /// plot on empty space below the line.
    static func domain(over values: [Double]) -> ClosedRange<Double> {
        let highest = values.max() ?? 0
        let lowest = values.min() ?? 0
        let top = highest > 0 ? highest * 1.08 : 1
        let bottom = lowest < 0 ? lowest * 1.08 : 0
        return bottom...max(top, bottom + 1)
    }
}
