import Charts
import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// Where the money went, whether more came in than went out, and what it all adds up to.
struct ReportsView: View {
    @Environment(BudgetModel.self) private var budget
    @Environment(\.modelContext) private var modelContext

    @State private var monthsBack = 12
    @State private var earliestMonth: YearMonth?
    @State private var netWorth: [NetWorthPoint] = []
    @State private var flows: [MonthlyFlow] = []
    @State private var spending: [SpendingSlice] = []

    /// How many categories are named before the rest are folded together. Past a handful the colours
    /// stop being tellable apart, so the tail becomes one neutral share.
    private let namedCategories = 5

    /// `monthsBack == 0` means everything on record.
    private var range: (start: YearMonth, end: YearMonth) {
        let end = YearMonth.current()
        guard monthsBack > 0 else {
            return (earliestMonth ?? end.adding(months: -11), end)
        }
        return (end.adding(months: -(monthsBack - 1)), end)
    }

    private var rangeLabel: String {
        let bounds = range
        return bounds.start == bounds.end
            ? bounds.end.displayName
            : "\(bounds.start.displayName) – \(bounds.end.displayName)"
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    periodPicker
                    spendingCard
                    incomeCard
                    netWorthCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Flame.groupedBackground)
            .navigationTitle("Reports")
            .modifier(Lifecycle(view: self))
        }
        #else
        // Side by side: a desktop window is wide enough for the reports to be read together, and a
        // column of three tall cards left two of them below the fold.
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 440), spacing: 16, alignment: .top)], spacing: 16) {
                spendingCard
                incomeCard
                netWorthCard
            }
            .padding(20)
        }
        .background(Flame.groupedBackground)
        .navigationTitle("Reports")
        .navigationSubtitle(rangeLabel)
        .toolbar {
            ToolbarItem(placement: .principal) { periodPicker.fixedSize() }
        }
        .modifier(Lifecycle(view: self))
        #endif
    }

    private var periodPicker: some View {
        Picker("Period", selection: $monthsBack) {
            Text("Month").tag(1)
            Text("6M").tag(6)
            Text("12M").tag(12)
            Text("24M").tag(24)
            Text("All").tag(0)
        }
        .pickerStyle(.segmented)
    }

    /// What either layout does around its cards.
    private struct Lifecycle: ViewModifier {
        let view: ReportsView

        func body(content: Content) -> some View {
            content
                .overlay {
                    if view.netWorth.isEmpty && view.spending.isEmpty {
                        ContentUnavailableView(
                            "Nothing to report yet",
                            systemImage: "chart.line.uptrend.xyaxis",
                            description: Text("Add transactions or import a YNAB export.")
                        )
                    }
                }
                .task(id: view.monthsBack) { view.rebuild() }
        }
    }

    // MARK: - Where it went

    /// The named categories, plus everything else as one share.
    private var shares: [(name: String, detail: String?, amount: MinorUnits, color: Color)] {
        let named = spending.prefix(namedCategories).enumerated().map { index, slice in
            // The engine works on the stored names; only what is shown is translated.
            (
                ProvidedName.category(slice.name) ?? slice.name,
                Optional(ProvidedName.group(slice.groupName) ?? slice.groupName),
                slice.amount,
                Flame.categoryColor(index)
            )
        }
        let rest = spending.dropFirst(namedCategories)
        guard !rest.isEmpty else { return named }
        let restTotal = rest.reduce(0) { $0 + $1.amount }
        return named + [(
            String(localized: "All others"),
            Counted.categories(rest.count),
            restTotal,
            Flame.categoricalRest
        )]
    }

    @ViewBuilder
    private var spendingCard: some View {
        if !spending.isEmpty {
            ReportCard(title: String(localized: "Where it went"), symbol: "chart.pie.fill") {
                ReportHeadline(
                    caption: rangeLabel,
                    value: budget.money(spending.reduce(0) { $0 + $1.amount })
                )
                ShareBar(parts: shares.map { ($0.amount.majorUnits, $0.color) })

                VStack(spacing: 10) {
                    HStack {
                        Text("Top categories")
                        Spacer()
                        Text("Spent")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                    ForEach(Array(shares.enumerated()), id: \.offset) { _, share in
                        ShareRow(
                            color: share.color,
                            name: share.name,
                            detail: share.detail,
                            amount: budget.money(share.amount)
                        )
                    }
                }
            }
        }
    }

    // MARK: - In against out

    @ViewBuilder
    private var incomeCard: some View {
        if !flows.isEmpty {
            ReportCard(title: String(localized: "In against out"), symbol: "chart.bar.fill") {
                Text(verdict)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Chart {
                    ForEach(flows, id: \.month) { flow in
                        BarMark(
                            x: .value("Month", flow.month.firstDay, unit: .month),
                            y: .value("Amount", flow.income.majorUnits)
                        )
                        .position(by: .value("Kind", "Income"))
                        .foregroundStyle(by: .value("Kind", "Income"))
                        .cornerRadius(3)

                        BarMark(
                            x: .value("Month", flow.month.firstDay, unit: .month),
                            y: .value("Amount", flow.spending.majorUnits)
                        )
                        .position(by: .value("Kind", "Spending"))
                        .foregroundStyle(by: .value("Kind", "Spending"))
                        .cornerRadius(3)
                    }
                }
                .chartForegroundStyleScale([
                    "Income": Flame.seriesIncome,
                    "Spending": Flame.seriesSpending,
                ])
                .chartYScale(domain: flowDomain)
                .chartLegend(position: .bottom, spacing: 12)
                .chartYAxis { amountAxis }
                .chartXAxis { monthAxis }
                .frame(height: 190)

                VStack(spacing: 8) {
                    ShareRow(
                        color: Flame.seriesIncome, name: String(localized: "Income"), detail: nil,
                        amount: budget.money(flows.reduce(0) { $0 + $1.income })
                    )
                    ShareRow(
                        color: Flame.seriesSpending, name: String(localized: "Spending"), detail: nil,
                        amount: budget.money(flows.reduce(0) { $0 + $1.spending })
                    )
                    Divider()
                    let net = flows.reduce(0) { $0 + $1.net }
                    HStack {
                        Text("Difference").font(.callout.weight(.medium))
                        Spacer()
                        Text(budget.money(net))
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Flame.amountColor(net))
                    }
                }
            }
        }
    }

    /// The range the bars actually occupy.
    ///
    /// Left to itself the axis rounded a single small negative month out to −$50K and spent half the
    /// plot on empty space below the line.
    private var flowDomain: ClosedRange<Double> {
        let values = flows.flatMap { [$0.income.majorUnits, $0.spending.majorUnits] }
        return domain(over: values)
    }

    /// Net worth is drawn from zero, because a chart of it that starts at $400K makes a steady year
    /// look like a cliff. Only the top is trimmed to the data.
    private var netWorthDomain: ClosedRange<Double> {
        domain(over: netWorth.map(\.net.majorUnits))
    }

    /// Zero to a little above the largest value, dipping below only if something is actually negative.
    private func domain(over values: [Double]) -> ClosedRange<Double> {
        let highest = values.max() ?? 0
        let lowest = values.min() ?? 0
        let top = highest > 0 ? highest * 1.08 : 1
        let bottom = lowest < 0 ? lowest * 1.08 : 0
        return bottom...max(top, bottom + 1)
    }

    /// Thousands named rather than spelled out, on the right where they do not push the plot over.
    private var amountAxis: some AxisContent {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine()
            AxisValueLabel {
                if let major = value.as(Double.self) {
                    Text(compactAxisAmount(major, symbol: budget.baseCurrency.symbol))
                }
            }
        }
    }

    /// Dates along the bottom, at a spacing the width can actually hold.
    private var monthAxis: some AxisContent {
        AxisMarks(values: .stride(by: .month, count: xAxisStride)) { value in
            AxisGridLine()
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Text(date.formatted(xAxisFormat))
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
    private var xAxisStride: Int {
        let months = max(flows.count, netWorth.count)
        guard months > 6 else { return 1 }
        let wanted = Int((Double(months) / 6).rounded(.up))
        return [1, 2, 3, 6, 12, 24, 60].first { $0 >= wanted } ?? 120
    }

    /// Months while the gap is short enough for them to mean something; years once it is not.
    private var xAxisFormat: Date.FormatStyle {
        switch xAxisStride {
        case ..<6: .dateTime.month(.abbreviated).locale(.display)
        case ..<12: .dateTime.month(.abbreviated).year(.twoDigits).locale(.display)
        default: .dateTime.year().locale(.display)
        }
    }

    /// What the bars amount to, in a sentence.
    private var verdict: String {
        let income = flows.reduce(0) { $0 + $1.income }
        let spent = flows.reduce(0) { $0 + $1.spending }
        guard income > 0 || spent > 0 else { return String(localized: "Nothing came in or went out.") }
        let net = income - spent
        let months = flows.count

        // Within a twentieth either way is not a trend, it is noise.
        let scale = max(income, spent)
        if abs(net) * 20 < scale {
            return months == 1
                ? String(localized: "You spent about as much as you made.")
                : String(localized: "On average you spend about as much as you make.")
        }
        let perMonth = budget.money(abs(net) / MinorUnits(max(months, 1)))
        if net > 0 {
            return months == 1
                ? String(localized: "You kept \(budget.money(net)).")
                : String(localized: "You keep about \(perMonth) a month.")
        }
        return months == 1
            ? String(localized: "You spent \(budget.money(-net)) more than you made.")
            : String(localized: "You spend about \(perMonth) a month more than you make.")
    }

    // MARK: - Net worth

    @ViewBuilder
    private var netWorthCard: some View {
        if let latest = netWorth.last {
            ReportCard(title: String(localized: "Net worth"), symbol: "building.columns.fill") {
                ReportHeadline(
                    caption: latest.month.displayName,
                    value: budget.money(latest.net),
                    tint: Flame.amountColor(latest.net)
                )

                VStack(spacing: 8) {
                    ShareRow(
                        color: Flame.seriesIncome, name: String(localized: "Assets"), detail: nil,
                        amount: budget.money(latest.assets)
                    )
                    ShareRow(
                        color: Flame.seriesSpending, name: String(localized: "Owed"), detail: nil,
                        amount: budget.money(latest.liabilities)
                    )
                }

                Chart(netWorth, id: \.month) { point in
                    AreaMark(
                        x: .value("Month", point.month.firstDay),
                        y: .value("Net worth", point.net.majorUnits)
                    )
                    .foregroundStyle(Flame.softGradient)
                    LineMark(
                        x: .value("Month", point.month.firstDay),
                        y: .value("Net worth", point.net.majorUnits)
                    )
                    .foregroundStyle(Flame.ember)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                }
                .chartYScale(domain: netWorthDomain)
                .chartYAxis { amountAxis }
                .chartXAxis { monthAxis }
                .frame(height: 170)
            }
        }
    }

    private func rebuild() {
        guard let input = try? BudgetInputBuilder.build(from: modelContext) else { return }
        earliestMonth = input.entries.map { YearMonth(containing: $0.date) }.min()
        let bounds = range
        let asOf = budget.activityCutoff
        netWorth = ReportBuilder.netWorth(input, from: bounds.start, through: bounds.end, asOf: asOf)
        flows = ReportBuilder.flows(input, from: bounds.start, through: bounds.end, asOf: asOf)
        spending = ReportBuilder.spendingByCategory(
            input, from: bounds.start, through: bounds.end, asOf: asOf
        )
    }
}

extension MinorUnits {
    /// Charts plot in major units; the ledger keeps minor ones.
    var majorUnits: Double { Double(self) / 100 }
}
