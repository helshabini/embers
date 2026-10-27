import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// A row at the top of Transactions that leads to something waiting on a decision.
struct AttentionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title).fontWeight(.medium)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(Color.orange)
        }
    }
}

/// Scheduled entries whose day has come.
///
/// Nothing here counts until it is approved. A scheduled payment that simply turned into a real one on
/// its date spent a subscription that had been cancelled in the meantime, without anyone noticing.
struct ApprovalListView: View {
    @Environment(BudgetModel.self) private var budget
    @Environment(\.modelContext) private var modelContext

    @State private var rows: [LedgerTransaction] = []
    @State private var editing: EditingTransaction?
    /// Worked out on the tap: the dialog renders again as it closes, which after a skip that deletes
    /// is a read of a destroyed row, and that is fatal.
    @State private var choice: Choice?

    private struct Choice {
        let transaction: LedgerTransaction
        let title: String
        let repeats: Bool
    }

    var body: some View {
        List {
            Section {
                ForEach(rows.filter(\.isLive)) { transaction in
                    Button {
                        choice = Choice(
                            transaction: transaction,
                            title: title(of: transaction),
                            repeats: RecurrenceWriter.repeats(transaction, in: modelContext)
                        )
                    } label: {
                        TransactionRow(
                            transaction: transaction,
                            showsAccount: true,
                            collapsesTransfer: transaction.isTransfer
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("approval-row")
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            approve(transaction)
                        } label: {
                            Label("Approve", systemImage: "checkmark")
                        }
                        .tint(Flame.inflow)
                    }
                }
            } footer: {
                Text("Their day has come, but none of them counts until you approve it. Skip one if the payment never went out.")
            }
        }
        .overlay {
            if rows.filter(\.isLive).isEmpty {
                ContentUnavailableView("Nothing to approve", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("To Approve")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Approve All") {
                    try? RecurrenceWriter.approveDue(in: modelContext, asOf: budget.activityCutoff)
                    budget.refresh(in: modelContext)
                }
                .disabled(rows.isEmpty)
                .accessibilityIdentifier("approve-all")
            }
        }
        .confirmationDialog(
            choice?.title ?? "",
            isPresented: Binding(get: { choice != nil }, set: { if !$0 { choice = nil } }),
            titleVisibility: .visible,
            presenting: choice
        ) { choice in
            Button("Approve") { approve(choice.transaction) }
            if choice.repeats {
                Button("Skip This One") { skip(choice.transaction) }
            } else {
                Button("Skip and Delete", role: .destructive) { skip(choice.transaction) }
            }
            Button("Edit") { editing = EditingTransaction(transaction: choice.transaction) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $editing) { editing in
            TransactionEditorView(account: nil, existing: editing.transaction)
        }
        .task { load() }
        .onChange(of: budget.revision) { _, _ in load() }
    }

    private func title(of transaction: LedgerTransaction) -> String {
        let date = transaction.date.formatted(.dateTime.day().month(.abbreviated).locale(.display))
        let amount = budget.money(MinorUnits(transaction.amountMinor))
        let payee = transaction.payee?.displayName ?? transaction.transferCounterAccount?.name
        return [payee, amount, date].compactMap { $0 }.joined(separator: " · ")
    }

    private func approve(_ transaction: LedgerTransaction) {
        try? RecurrenceWriter.approve(transaction, in: modelContext)
        budget.refresh(in: modelContext)
    }

    private func skip(_ transaction: LedgerTransaction) {
        try? RecurrenceWriter.skip(transaction, in: modelContext)
        budget.refresh(in: modelContext)
    }

    private func load() {
        rows = (try? RecurrenceWriter.dueForApproval(in: modelContext, asOf: budget.activityCutoff)) ?? []
    }
}

/// Entries in a budget account with no category.
///
/// Their money has moved without coming out of any envelope or out of Ready to Assign, so the plan
/// cannot see it, and Ready to Assign stops matching the accounts with every envelope covered.
/// Choosing a category is the whole fix, so a tap goes straight to the categories.
struct UncategorizedListView: View {
    @Environment(BudgetModel.self) private var budget
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BudgetCategoryModel.order) private var categories: [BudgetCategoryModel]

    @State private var rows: [LedgerTransaction] = []

    var body: some View {
        List {
            Section {
                ForEach(rows.filter(\.isLive)) { transaction in
                    NavigationLink {
                        CategoryPickerView(categories: categories.selectable, selected: nil) { picked in
                            assign(picked, to: transaction)
                        }
                    } label: {
                        TransactionRow(transaction: transaction, showsAccount: true)
                    }
                    .accessibilityIdentifier("uncategorized-row")
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }
            } footer: {
                Text("This money has moved without coming out of any category, so the plan cannot see it. Choose a category for each.")
            }
        }
        .overlay {
            if rows.filter(\.isLive).isEmpty {
                ContentUnavailableView("Everything has a category", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("Uncategorized")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .onChange(of: budget.revision) { _, _ in load() }
    }

    private func assign(_ category: BudgetCategoryModel?, to transaction: LedgerTransaction) {
        guard let category, transaction.isLive else { return }
        transaction.category = category
        try? modelContext.save()
        budget.refresh(in: modelContext)
    }

    /// Newest first, as everywhere else in the app. The engine found them; this only reads those rows.
    private func load() {
        let wanted = budget.uncategorized
        guard !wanted.isEmpty else {
            rows = []
            return
        }
        rows = (try? modelContext.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { wanted.contains($0.identifier) },
                sortBy: LedgerTransaction.newestFirst
            )
        )) ?? []
    }
}
