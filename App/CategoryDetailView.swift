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
    /// The Assigned figure being typed, with the keypad up.
    @State private var assignSession: AssignSession?
    @State private var sheet: Sheet?

    /// One sheet per view, so both kinds go through one `.sheet(item:)`.
    private enum Sheet: Identifiable {
        case edit(EditingTransaction)
        case add

        var id: String {
            switch self {
            case let .edit(editing): "edit-\(editing.id.hashValue)"
            case .add: "add"
            }
        }
    }

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
                    Button(action: startAssigning) {
                        HStack {
                            Text("Assigned")
                            Spacer()
                            AssignedField(amount: budget.money(state.assigned), isEditing: assignSession != nil)
                                .frame(width: PlanColumns.assigned)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("assigned-field")
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
                                sheet = .edit(EditingTransaction(transaction: transaction))
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
            .safeAreaInset(edge: .bottom) {
                if let opened = assignSession {
                    // Falls back to the session it opened on: while it slides away the session is
                    // already gone, and a recompute landing then draws it once more.
                    AssignKeypad(
                        session: Binding(get: { assignSession ?? opened }, set: { assignSession = $0 }),
                        onDone: finishAssigning,
                        onCancel: { withAnimation(.snappy) { assignSession = nil } }
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            .onDisappear(perform: finishAssigning)
            .navigationTitle(category.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                // Out of the way while the keypad is up, which takes the foot of the screen.
                if category.kind == .normal, assignSession == nil {
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            sheet = .add
                        } label: {
                            Label("Add Transaction", systemImage: "plus.circle.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .accessibilityIdentifier("category-add-transaction")
                    }
                }
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case let .edit(editing):
                    // Not `transaction.account`: this is re-read as the sheet closes, after a delete.
                    TransactionEditorView(account: nil, existing: editing.transaction)
                case .add:
                    TransactionEditorView(account: nil, existing: nil, category: category)
                }
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

    private func startAssigning() {
        guard assignSession == nil else { return }
        withAnimation(.snappy) {
            assignSession = AssignSession(
                category: category, month: month, shown: state.assigned, currency: budget.baseCurrency
            )
        }
    }

    private func finishAssigning() {
        guard let session = assignSession else { return }
        session.commit(in: modelContext, budget: budget)
        withAnimation(.snappy) { assignSession = nil }
    }
}
