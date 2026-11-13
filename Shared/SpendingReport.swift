import Charts
import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

extension SpendingDimension {
    var title: LocalizedStringKey {
        switch self {
        case .category: "Categories"
        case .group: "Groups"
        case .payee: "Payees"
        }
    }
}

extension SpendingShare {
    /// The stored name as the reader should see it: provided names translated, and the entries with
    /// no payee called that rather than left blank.
    var displayName: String {
        switch key {
        case .category: ProvidedName.category(name) ?? name
        case .group: ProvidedName.group(name) ?? name
        case .payee: name.isEmpty ? String(localized: "(no payee)") : (ProvidedName.payee(name) ?? name)
        case .transfer: String(localized: "Transfer: \(name)")
        }
    }

    var detail: String? {
        groupName.map { ProvidedName.group($0) ?? $0 }
    }
}

/// Where the money went, by category, group or payee, each one a way in to the detail behind it.
struct SpendingReport: View {
    let input: BudgetInput
    let range: ReportRange

    @Environment(BudgetModel.self) private var budget
    @State private var dimension = SpendingDimension.category
    @State private var shares: [SpendingShare] = []
    @State private var trend: [MonthlyAmount] = []

    var body: some View {
        VStack(spacing: 16) {
            ReportCard(title: String(localized: "Where it went"), symbol: "chart.pie.fill") {
                ReportHeadline(caption: range.label, value: budget.money(total))
                if range.months > 1 {
                    Text("About \(budget.money(total / MinorUnits(range.months))) a month")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                SpendingTrendChart(trend: trend)
            }

            ReportCard(title: String(localized: "Breakdown"), symbol: "list.bullet") {
                Picker("Break down by", selection: $dimension) {
                    ForEach(SpendingDimension.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("spending-dimension")

                SpendingShareList(shares: shares, keys: [])
            }
        }
        .task(id: TaskKey(dimension: dimension, range: range)) {
            shares = ReportBuilder.spending(
                input, from: range.start, through: range.end, asOf: range.asOf, by: dimension
            )
            trend = ReportBuilder.monthlySpending(input, from: range.start, through: range.end, asOf: range.asOf)
        }
    }

    private var total: MinorUnits { shares.reduce(0) { $0 + $1.amount } }

    private struct TaskKey: Equatable {
        var dimension: SpendingDimension
        var range: ReportRange
    }
}

/// Spending per month, as bars.
struct SpendingTrendChart: View {
    let trend: [MonthlyAmount]

    @Environment(BudgetModel.self) private var budget

    var body: some View {
        let currency = budget.baseCurrency
        let axes = ReportAxes(currency: currency, months: trend.count)
        Chart(trend, id: \.month) { point in
            BarMark(
                x: .value("Month", point.month.firstDay, unit: .month),
                y: .value("Spent", point.amount.major(currency))
            )
            .foregroundStyle(Flame.seriesSpending)
            .cornerRadius(3)
        }
        .chartYScale(domain: ReportAxes.domain(over: trend.map { $0.amount.major(currency) }))
        .chartYAxis { axes.amount }
        .chartXAxis { axes.month }
        .frame(height: reportChartHeight * 0.75)
    }
}

/// A share bar and every share beneath it, each leading to its own detail.
struct SpendingShareList: View {
    let shares: [SpendingShare]
    /// What the list is already narrowed to; each row narrows it one step further.
    let keys: [SpendingKey]

    @Environment(BudgetModel.self) private var budget
    @State private var showsAll = false

    /// Named in colour before the rest share a neutral. Past a handful the colours stop being
    /// tellable apart.
    private let coloured = 5
    /// Rows drawn before "Show all": a budget can have hundreds of payees.
    private let firstRows = 20

    var body: some View {
        let total = shares.reduce(0) { $0 + $1.amount }
        VStack(alignment: .leading, spacing: 12) {
            if shares.isEmpty {
                Text("Nothing spent in this period.")
                    .foregroundStyle(.secondary)
            } else {
                ShareBar(parts: barParts)
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { index, share in
                        NavigationLink(value: SpendingDrill(keys: keys + [share.key], title: share.displayName)) {
                            HStack(spacing: 10) {
                                ShareRow(
                                    color: Flame.categoryColor(index),
                                    name: share.displayName,
                                    detail: share.detail,
                                    amount: budget.money(share.amount)
                                )
                                Text(percent(share.amount, of: total))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 40, alignment: .trailing)
                                Image(systemName: "chevron.forward")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("spending-share")
                        if index < visible.count - 1 { Divider() }
                    }
                }
                if shares.count > firstRows {
                    Button(showsAll ? "Show fewer" : "Show all \(shares.count)") {
                        withAnimation { showsAll.toggle() }
                    }
                    .font(.callout.weight(.medium))
                }
            }
        }
    }

    private var visible: ArraySlice<SpendingShare> {
        showsAll ? shares[...] : shares.prefix(firstRows)
    }

    /// The coloured few, then the rest as one neutral segment.
    private var barParts: [(value: Double, color: Color)] {
        let named = shares.prefix(coloured).enumerated().map { index, share in
            (Double(share.amount), Flame.categoryColor(index))
        }
        let rest = shares.dropFirst(coloured).reduce(0) { $0 + $1.amount }
        return rest > 0 ? named + [(Double(rest), Flame.categoricalRest)] : named
    }

    private func percent(_ amount: MinorUnits, of total: MinorUnits) -> String {
        guard total > 0 else { return "" }
        return (Double(amount) / Double(total)).formatted(.percent.precision(.fractionLength(0...1)).locale(.display))
    }
}

/// One category, group or payee — or several at once — over the report's period: the trend, what
/// it breaks down into, and the transactions themselves.
struct SpendingDetailView: View {
    let drill: SpendingDrill
    let input: BudgetInput
    let range: ReportRange

    @Environment(BudgetModel.self) private var budget
    @Environment(\.modelContext) private var modelContext

    @State private var dimension: SpendingDimension?
    @State private var shares: [SpendingShare] = []
    @State private var trend: [MonthlyAmount] = []
    @State private var transactions: [LedgerTransaction] = []
    @State private var transactionCount = 0

    /// The latest few are listed; the register is where the whole history lives.
    private let listed = 50

    /// What is left to break it down by. A category is already inside one group, so it is never
    /// broken down by group.
    private var dimensions: [SpendingDimension] {
        let used = Set(drill.keys.map(\.dimension))
        return SpendingDimension.allCases.filter { candidate in
            !used.contains(candidate) && !(candidate == .group && used.contains(.category))
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ReportCard(title: range.label, symbol: "calendar") {
                    let total = trend.reduce(0) { $0 + $1.amount }
                    ReportHeadline(caption: nil, value: budget.money(total))
                    if range.months > 1 {
                        Text("About \(budget.money(total / MinorUnits(range.months))) a month")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    SpendingTrendChart(trend: trend)
                }

                if let dimension, !dimensions.isEmpty {
                    ReportCard(title: String(localized: "Breakdown"), symbol: "list.bullet") {
                        if dimensions.count > 1 {
                            Picker("Break down by", selection: Binding(
                                get: { dimension },
                                set: { self.dimension = $0 }
                            )) {
                                ForEach(dimensions, id: \.self) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        } else {
                            Text(dimension.title).font(.subheadline.weight(.medium))
                        }
                        SpendingShareList(shares: shares, keys: drill.keys)
                    }
                }

                ReportCard(title: String(localized: "Transactions"), symbol: "list.bullet.rectangle") {
                    if transactions.isEmpty {
                        Text("Nothing spent in this period.").foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(transactions.enumerated()), id: \.offset) { index, transaction in
                                ReportTransactionRow(transaction: transaction)
                                    .padding(.vertical, 7)
                                if index < transactions.count - 1 { Divider() }
                            }
                        }
                        if transactionCount > transactions.count {
                            Text("The latest \(transactions.count) of \(transactionCount).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(16)
            #if os(macOS)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            #endif
        }
        .background(Flame.groupedBackground)
        .navigationTitle(drill.title)
        .inlineNavigationTitle()
        .task {
            if dimension == nil { dimension = dimensions.first }
            trend = ReportBuilder.monthlySpending(
                input, from: range.start, through: range.end, asOf: range.asOf, matching: drill.keys
            )
            loadTransactions()
        }
        .task(id: dimension) {
            guard let dimension else { return }
            shares = ReportBuilder.spending(
                input, from: range.start, through: range.end, asOf: range.asOf, by: dimension, matching: drill.keys
            )
        }
    }

    private func loadTransactions() {
        let entries = ReportBuilder.spendingEntries(
            input, from: range.start, through: range.end, asOf: range.asOf, matching: drill.keys
        )
        transactionCount = entries.count
        let latest = entries.map(\.entry).sorted { $0.date > $1.date }.prefix(listed).map(\.id)
        let descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { latest.contains($0.identifier) },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        transactions = (try? modelContext.fetch(descriptor)) ?? []
    }
}

/// A transaction as a report lists it: when, who, what for, and how much.
struct ReportTransactionRow: View {
    let transaction: LedgerTransaction

    @Environment(BudgetModel.self) private var budget

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(budget.money(MinorUnits(transaction.amountMinor)))
                .monospacedDigit()
                .foregroundStyle(Flame.amountColor(MinorUnits(transaction.amountMinor)))
        }
        .font(.callout)
    }

    /// Worded as the register words it, so a transfer names where it went. A split's line has no
    /// payee of its own; it is the parent's.
    private var title: String {
        if transaction.payee == nil, let parent = transaction.parent, parent.payee != nil {
            return TransactionWording(transaction: parent).title
        }
        return TransactionWording(transaction: transaction).title
    }

    private var subtitle: String {
        let date = transaction.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: .display))
        guard let category = transaction.category?.displayName else { return date }
        return "\(date) · \(category)"
    }
}
