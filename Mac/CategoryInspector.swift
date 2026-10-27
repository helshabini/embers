import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// What a category holds this month, and everything that hit it: the phone's category sheet, kept
/// open beside the Plan.
///
/// The Plan answers "how much is left"; this answers "on what". Both are needed before deciding
/// whether a number is a problem.
struct CategoryInspector: View {
    let category: BudgetCategoryModel
    let month: YearMonth

    @Environment(BudgetModel.self) private var budget
    @Environment(\.modelContext) private var modelContext
    @Query private var transactions: [LedgerTransaction]

    init(category: BudgetCategoryModel, month: YearMonth) {
        self.category = category
        self.month = month
        let categoryID = category.identifier
        let start = month.firstDay
        let end = month.next.firstDay
        _transactions = Query(
            filter: #Predicate<LedgerTransaction> { transaction in
                transaction.category?.identifier == categoryID
                    && transaction.date >= start
                    && transaction.date < end
            },
            sort: LedgerTransaction.newestFirst
        )
    }

    var body: some View {
        // The category can be deleted from the plan editor while this is open.
        if category.isDeleted || category.modelContext == nil {
            ContentUnavailableView("No category selected", systemImage: "list.bullet.rectangle")
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FlameHeader(
                    title: String(localized: "Available"),
                    subtitle: month.displayName,
                    background: background
                ) {
                    Text(budget.money(state.available))
                        .font(.title.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }

                Text(category.displayName)
                    .font(.title3.weight(.semibold))

                Grid(alignment: .leading, verticalSpacing: 6) {
                    line(String(localized: "Carried in"), state.carriedIn)
                    line(String(localized: "Assigned"), state.assigned)
                    line(String(localized: "Spent"), state.activity, colored: true)
                }

                if case let .underfunded(needed) = budget.status(of: category) {
                    action(
                        String(localized: "Assign \(budget.money(needed)) for what is still to come"),
                        note: String(localized: "Scheduled for later this month: \(budget.money(-budget.upcoming(of: category))). Assigning it now means the money is waiting when it comes due."),
                        identifier: "fund-upcoming",
                        perform: fundShortfall
                    )
                } else if budget.shortfall(of: category) > 0 {
                    action(
                        String(localized: "Assign \(budget.money(budget.shortfall(of: category))) to Cover"),
                        note: String(localized: "Overspent. Next month pays for it unless you cover it."),
                        identifier: "cover-overspending",
                        perform: fundShortfall
                    )
                }

                if setAsideForNothing > 0 {
                    action(
                        String(localized: "Move \(budget.money(setAsideForNothing)) to Ready to Assign"),
                        note: String(localized: "This card is closed, and this money is set aside for a payment that will not be made. Move it to Ready to Assign to give it a job."),
                        identifier: "release-closed-card",
                        perform: release
                    )
                }

                Divider()
                transactionList
            }
            .padding(16)
        }
    }

    private func line(_ title: String, _ amount: MinorUnits, colored: Bool = false) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(budget.money(amount))
                .monospacedDigit()
                .foregroundStyle(colored ? Flame.amountColor(amount) : .primary)
                .gridColumnAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func action(_ title: String, note: String, identifier: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(title, action: perform)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(identifier)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transactionList: some View {
        let live = transactions.filter(\.isLive)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(live.count) transactions")
                    .font(.headline)
                Spacer()
                Text(budget.money(transactionTotal(live)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if live.isEmpty {
                Text("Nothing hit this category in \(month.displayName).")
                    .foregroundStyle(.secondary)
            }
            ForEach(live) { transaction in
                let wording = TransactionWording(transaction: transaction)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(wording.title).lineLimit(1)
                        Text(verbatim: "\(wording.shortDate) · \(transaction.account?.name ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(budget.money(MinorUnits(transaction.amountMinor)))
                        .monospacedDigit()
                        .foregroundStyle(Flame.amountColor(MinorUnits(transaction.amountMinor)))
                }
                .opacity(budget.hasHappened(transaction) ? 1 : 0.55)
            }
        }
    }

    private var state: CategoryMonthState { budget.state(of: category) }

    private var background: LinearGradient {
        switch budget.status(of: category) {
        case .overspent: Flame.outflowGradient
        case .funded: Flame.inflowGradient
        case .empty: Flame.neutralGradient
        case .creditOverspent, .underfunded: Flame.gradient
        }
    }

    /// Split lines carry the category, so they are what shows here and what adds up. Only what has
    /// happened, so the total agrees with Spent above.
    private func transactionTotal(_ live: [LedgerTransaction]) -> MinorUnits {
        MinorUnits(live.filter { budget.hasHappened($0) }.reduce(0) { $0 + $1.amountMinor })
    }

    private var setAsideForNothing: MinorUnits { budget.setAsideForNothing(by: category) }

    private func fundShortfall() {
        let needed = budget.shortfall(of: category)
        guard needed > 0 else { return }
        try? AssignmentWriter.adjustAssigned(by: needed, category: category, month: month, in: modelContext)
        budget.refresh(in: modelContext)
    }

    /// Into the current month, where the money is: the figure was worked out there.
    private func release() {
        try? AssignmentWriter.adjustAssigned(
            by: -setAsideForNothing, category: category, month: .current(), in: modelContext
        )
        budget.refresh(in: modelContext)
    }
}
