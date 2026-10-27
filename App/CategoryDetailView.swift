import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// What a category holds this month, and everything that hit it.
///
/// The Plan screen answers "how much is left"; this answers "on what". Both are needed before
/// deciding whether a number is a problem.
struct CategoryDetailView: View {
    let category: BudgetCategoryModel
    let month: YearMonth

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(BudgetModel.self) private var budget

    @Query private var transactions: [LedgerTransaction]
    @State private var assignedText = ""
    /// What the Assigned field held before the person typed. What is saved is the change from this,
    /// so an edit from another device that lands while they type is added to, not undone.
    @State private var shownAssigned: MinorUnits = 0
    @State private var editing: EditingTransaction?

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
        NavigationStack {
            List {
                Section {
                    FlameHeader(title: String(localized: "Available"), subtitle: month.displayName) {
                        Text(budget.money(state.available))
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                }

                Section {
                    LabeledContent("Carried in", value: budget.money(state.carriedIn))
                    HStack {
                        Text("Assigned")
                        Spacer()
                        TextField("0", text: $assignedText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .onSubmit(saveAssigned)
                        Button("Set", action: saveAssigned)
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                    }
                    LabeledContent("Spent") {
                        Text(budget.money(state.activity))
                            .foregroundStyle(Flame.amountColor(state.activity))
                    }
                }

                if case let .underfunded(needed) = budget.status(of: category) {
                    Section {
                        Button("Assign \(budget.money(needed)) for what is still to come", action: fundUpcoming)
                            .accessibilityIdentifier("fund-upcoming")
                    } footer: {
                        Text("Scheduled for later this month: \(budget.money(-budget.upcoming(of: category))). Assigning it now means the money is waiting when it comes due.")
                    }
                }

                if setAsideForNothing > 0 {
                    Section {
                        Button("Move \(budget.money(setAsideForNothing)) to Ready to Assign", action: release)
                            .accessibilityIdentifier("release-closed-card")
                    } footer: {
                        Text("This card is closed, and this money is set aside for a payment that will not be made. Move it to Ready to Assign to give it a job.")
                    }
                }

                Section {
                    if transactions.isEmpty {
                        Text("Nothing hit this category in \(month.displayName).")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(transactions.filter(\.isLive)) { transaction in
                            Button {
                                editing = EditingTransaction(transaction: transaction)
                            } label: {
                                TransactionRow(transaction: transaction, showsAccount: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    HStack {
                        Text("\(transactions.count) transactions")
                        Spacer()
                        Text(budget.money(transactionTotal))
                    }
                }
            }
            .navigationTitle(category.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $editing) { editing in
                // Not `transaction.account`: this is re-read as the sheet closes, after a delete.
                TransactionEditorView(account: nil, existing: editing.transaction)
            }
            .onAppear {
                shownAssigned = state.assigned
                assignedText = state.assigned == 0
                    ? ""
                    : Money(minorUnits: state.assigned, currency: budget.baseCurrency)
                        .formatted(showCurrencySymbol: false)
            }
        }
    }

    private var state: CategoryMonthState { budget.state(of: category) }

    /// Split lines carry the category, so they are what shows here and what adds up. Only what has
    /// happened, so the total agrees with Spent above.
    private var transactionTotal: MinorUnits {
        MinorUnits(transactions.filter { $0.isLive && budget.hasHappened($0) }.reduce(0) { $0 + $1.amountMinor })
    }

    private var setAsideForNothing: MinorUnits { budget.setAsideForNothing(by: category) }

    private func fundUpcoming() {
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
        dismiss()
    }

    private func saveAssigned() {
        let amount = Money.parse(assignedText, currency: budget.baseCurrency)?.minorUnits ?? 0
        try? AssignmentWriter.setAssigned(
            amount, shown: shownAssigned, category: category, month: month, in: modelContext
        )
        // Saved twice without retyping, the second must find nothing left to change.
        shownAssigned = amount
        budget.refresh(in: modelContext)
    }
}
