import Charts
import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// The reports there are, one shown at a time.
enum ReportKind: String, CaseIterable, Identifiable {
    case spending
    case cashFlow
    case inAndOut
    case netWorth

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .spending: "Spending"
        case .cashFlow: "Cash Flow"
        case .inAndOut: "In & Out"
        case .netWorth: "Net Worth"
        }
    }

    var symbol: String {
        switch self {
        case .spending: "chart.pie.fill"
        case .cashFlow: "arrow.triangle.branch"
        case .inAndOut: "chart.bar.fill"
        case .netWorth: "building.columns.fill"
        }
    }
}

/// Spending narrowed to one category, group or payee, or several of them at once.
struct SpendingDrill: Hashable {
    var keys: [SpendingKey]
    var title: String
}

/// The span every report covers, and what has happened by now.
struct ReportRange: Equatable {
    var start: YearMonth
    var end: YearMonth
    var asOf: Date

    var months: Int { YearMonth.range(from: start, through: end).count }

    var label: String {
        start == end ? end.displayName : "\(start.displayName) – \(end.displayName)"
    }
}

/// Where the money went, where it came from, whether more came in than went out, and what it all
/// adds up to.
///
/// One report at a time, each at full size. Side by side, three cards shared a window and the net
/// worth chart was cut off at its foot; on the phone, the last was three screens down.
struct ReportsView: View {
    @Environment(BudgetModel.self) private var budget
    @Environment(\.modelContext) private var modelContext

    @State private var report = ReportKind.spending
    @State private var monthsBack = 12
    @State private var path: [SpendingDrill] = []
    @State private var input: BudgetInput?
    @State private var earliestMonth: YearMonth?

    @State private var netWorth: [NetWorthPoint] = []
    @State private var flows: [MonthlyFlow] = []
    @State private var cashFlow: CashFlow?

    /// `monthsBack == 0` means everything on record.
    private var range: ReportRange {
        let end = YearMonth.current()
        let start = monthsBack > 0
            ? end.adding(months: -(monthsBack - 1))
            : (earliestMonth ?? end.adding(months: -11))
        return ReportRange(start: start, end: end, asOf: budget.activityCutoff)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    #if os(iOS)
                    ReportTabs(selection: $report)
                    periodPicker
                    #else
                    ReportTabs(selection: $report)
                        .frame(maxWidth: 560)
                    #endif
                    selectedReport
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 16)
                #if os(macOS)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                #endif
            }
            .background(Flame.groupedBackground)
            .navigationTitle("Reports")
            #if os(macOS)
            .navigationSubtitle(range.label)
            .toolbar {
                ToolbarItem(placement: .principal) { periodPicker.fixedSize() }
            }
            #endif
            .overlay {
                if input != nil, netWorth.isEmpty, cashFlow?.isEmpty ?? true {
                    ContentUnavailableView(
                        "Nothing to report yet",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Add transactions or import a YNAB export.")
                    )
                }
            }
            .navigationDestination(for: SpendingDrill.self) { drill in
                if let input {
                    SpendingDetailView(drill: drill, input: input, range: range)
                }
            }
        }
        // Not on every recompute: a tab that has been opened stays alive, and reading the register
        // after each edit made elsewhere is a cost nobody looking at another tab should pay.
        .task(id: monthsBack) { rebuild() }
    }

    private var horizontalPadding: CGFloat {
        #if os(macOS)
        24
        #else
        16
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

    @ViewBuilder
    private var selectedReport: some View {
        if let input {
            switch report {
            case .spending:
                SpendingReport(input: input, range: range)
            case .cashFlow:
                if let cashFlow {
                    CashFlowReport(flow: cashFlow, range: range) { path.append($0) }
                }
            case .inAndOut:
                InAndOutReport(flows: flows, range: range)
            case .netWorth:
                NetWorthReport(points: netWorth, range: range)
            }
        }
    }

    private func rebuild() {
        guard let built = try? BudgetInputBuilder.build(from: modelContext, withPayees: true) else { return }
        earliestMonth = built.entries.map { YearMonth(containing: $0.date) }.min()
        let bounds = range
        netWorth = ReportBuilder.netWorth(built, from: bounds.start, through: bounds.end, asOf: bounds.asOf)
        flows = ReportBuilder.flows(built, from: bounds.start, through: bounds.end, asOf: bounds.asOf)
        cashFlow = ReportBuilder.cashFlow(built, from: bounds.start, through: bounds.end, asOf: bounds.asOf)
        input = built
    }
}

/// The row of reports to choose from. A segmented control on the Mac, where there is room for one;
/// on the phone a row of chips that scrolls, because four segments in a long language cut every
/// label short.
struct ReportTabs: View {
    @Binding var selection: ReportKind

    var body: some View {
        #if os(macOS)
        Picker("Report", selection: $selection) {
            ForEach(ReportKind.allCases) { kind in
                Label(kind.title, systemImage: kind.symbol).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
        #else
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ReportKind.allCases) { kind in
                    Button {
                        selection = kind
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(selection == kind ? Flame.ember : Flame.cardBackground))
                            .foregroundStyle(selection == kind ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("report-\(kind.rawValue)")
                    .accessibilityAddTraits(selection == kind ? .isSelected : [])
                }
            }
        }
        #endif
    }
}

/// Taller on a desktop, where a report has the window to itself.
let reportChartHeight: CGFloat = {
    #if os(macOS)
    320
    #else
    220
    #endif
}()

// MARK: - In against out

struct InAndOutReport: View {
    let flows: [MonthlyFlow]
    let range: ReportRange

    @Environment(BudgetModel.self) private var budget

    var body: some View {
        ReportCard(title: String(localized: "In against out"), symbol: "chart.bar.fill") {
            Text(verdict)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            let currency = budget.baseCurrency
            let axes = ReportAxes(currency: currency, months: flows.count)
            Chart {
                ForEach(flows, id: \.month) { flow in
                    BarMark(
                        x: .value("Month", flow.month.firstDay, unit: .month),
                        y: .value("Amount", flow.income.major(currency))
                    )
                    .position(by: .value("Kind", "Income"))
                    .foregroundStyle(by: .value("Kind", "Income"))
                    .cornerRadius(3)

                    BarMark(
                        x: .value("Month", flow.month.firstDay, unit: .month),
                        y: .value("Amount", flow.spending.major(currency))
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
            .chartYScale(domain: ReportAxes.domain(
                over: flows.flatMap { [$0.income.major(currency), $0.spending.major(currency)] }
            ))
            .chartLegend(position: .bottom, spacing: 12)
            .chartYAxis { axes.amount }
            .chartXAxis { axes.month }
            .frame(height: reportChartHeight)

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
}

// MARK: - Net worth

/// What is owned, what is owed, and the difference, month by month.
///
/// The chart used to draw only the difference, in the spending orange, under a key of green assets
/// and orange debts — so it read as a chart of debts with the assets missing. It now draws all three,
/// each in its own colour and named in the chart's own legend.
struct NetWorthReport: View {
    let points: [NetWorthPoint]
    let range: ReportRange

    @Environment(BudgetModel.self) private var budget

    var body: some View {
        if let latest = points.last {
            ReportCard(title: String(localized: "Net worth"), symbol: "building.columns.fill") {
                ReportHeadline(
                    caption: latest.month.displayName,
                    value: budget.money(latest.net),
                    tint: Flame.amountColor(latest.net)
                )
                if let first = points.first, points.count > 1 {
                    let change = latest.net - first.net
                    Text(change >= 0
                         ? String(localized: "Up \(budget.money(change)) since \(first.month.displayName)")
                         : String(localized: "Down \(budget.money(-change)) since \(first.month.displayName)"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                chart

                VStack(spacing: 8) {
                    ShareRow(
                        color: Flame.seriesIncome, name: String(localized: "Assets"), detail: nil,
                        amount: budget.money(latest.assets)
                    )
                    ShareRow(
                        color: Flame.seriesSpending, name: String(localized: "Debts"), detail: nil,
                        amount: budget.money(latest.liabilities)
                    )
                    Divider()
                    HStack {
                        Text("Net worth").font(.callout.weight(.medium))
                        Spacer()
                        Text(budget.money(latest.net))
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Flame.amountColor(latest.net))
                    }
                }
            }
        }
    }

    private var assetsLabel: String { String(localized: "Assets") }
    private var debtsLabel: String { String(localized: "Debts") }
    private var netLabel: String { String(localized: "Net worth") }

    /// Assets above the line, debts below it, and net worth drawn across both.
    private var chart: some View {
        let currency = budget.baseCurrency
        let axes = ReportAxes(currency: currency, months: points.count)
        return Chart {
            ForEach(points, id: \.month) { point in
                BarMark(
                    x: .value("Month", point.month.firstDay, unit: .month),
                    y: .value("Amount", point.assets.major(currency))
                )
                .foregroundStyle(by: .value("Series", assetsLabel))
                .opacity(0.55)
                BarMark(
                    x: .value("Month", point.month.firstDay, unit: .month),
                    y: .value("Amount", point.liabilities.major(currency))
                )
                .foregroundStyle(by: .value("Series", debtsLabel))
                .opacity(0.55)
            }
            ForEach(points, id: \.month) { point in
                LineMark(
                    x: .value("Month", point.month.firstDay, unit: .month),
                    y: .value("Amount", point.net.major(currency))
                )
                .foregroundStyle(by: .value("Series", netLabel))
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                .interpolationMethod(.monotone)
                .symbol(.circle)
                .symbolSize(points.count > 24 ? 0 : 24)
            }
        }
        .chartForegroundStyleScale([
            assetsLabel: Flame.seriesIncome,
            debtsLabel: Flame.seriesSpending,
            netLabel: Color.primary,
        ])
        .chartYScale(domain: ReportAxes.domain(
            over: points.flatMap { [$0.assets.major(currency), $0.liabilities.major(currency), $0.net.major(currency)] }
        ))
        .chartLegend(position: .bottom, spacing: 12)
        .chartYAxis { axes.amount }
        .chartXAxis { axes.month }
        .frame(height: reportChartHeight)
    }
}
