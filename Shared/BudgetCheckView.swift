import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// What the plan found that it could not settle on its own.
///
/// Everything mechanical is already mended by the time this is read. What is left is money crossing
/// the edge of the budget without saying which envelope it belongs to, which only the person who
/// moved it knows, and money left with a card that was closed before closing required it to be empty.
struct BudgetCheckView: View {
    @Environment(BudgetModel.self) private var budget
    @Environment(\.modelContext) private var modelContext
    @State private var editing: EditingTransaction?
    @Query(filter: #Predicate<BudgetCategoryModel> { $0.hidden }) private var hiddenCategories: [BudgetCategoryModel]

    var body: some View {
        List {
            if budget.findings.isClear && setAsideForNothing.isEmpty {
                Section {
                    Label("Nothing needs your attention", systemImage: "checkmark.seal")
                        .foregroundStyle(Flame.inflow)
                } footer: {
                    Text(
                        "Transfers are paired, the credit card categories match your accounts, and every transfer across the edge of the budget says where it belongs."
                    )
                }
            } else {
                if !unresolved.isEmpty {
                    Section {
                        ForEach(unresolved.filter(\.isLive)) { transaction in
                            Button {
                                editing = EditingTransaction(transaction: transaction)
                            } label: {
                                FindingRow(transaction: transaction)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("finding-row")
                        }
                    } header: {
                        Text("Money crossing the budget with no category")
                    } footer: {
                        Text(
                            "These moved between an account you budget and one you only track, without saying which envelope. Until one is chosen the plan treats them as money to assign. Tap to decide."
                        )
                    }
                }

                if !setAsideForNothing.isEmpty {
                    Section {
                        ForEach(setAsideForNothing, id: \.category.identifier) { item in
                            HStack {
                                Text(item.category.displayName)
                                Spacer()
                                Button("Move \(budget.money(item.amount)) to Ready to Assign") {
                                    release(item.amount, from: item.category)
                                }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                            }
                            .accessibilityIdentifier("closed-card-finding")
                        }
                    } header: {
                        Text("Money left with closed cards")
                    } footer: {
                        Text(
                            "These cards are closed, but their payment categories still hold money for payments that will not be made. Closing the card hid the category, so this money cannot be seen on the Plan."
                        )
                    }
                }

                if budget.findings.unpairedTransfers > 0 {
                    Section {
                        LabeledContent(
                            "Transfers missing their other half",
                            value: "\(budget.findings.unpairedTransfers)"
                        )
                    } footer: {
                        Text(
                            "One side of these is not in the budget, so deleting or editing them changes only what is here. Nothing is miscounted by it."
                        )
                    }
                }
            }
        }
        .navigationTitle("Check")
        .sheet(item: $editing) { editing in
            // Not `transaction.account`: this is re-read as the sheet closes, after a delete.
            #if os(iOS)
            TransactionEditorView(account: nil, existing: editing.transaction)
            #else
            TransactionEditorSheet(transaction: editing.transaction)
            #endif
        }
        .onChange(of: budget.revision) { _, _ in budget.recheck(in: modelContext) }
        .task { budget.recheck(in: modelContext) }
    }

    /// Only a closed card's category can hold this, and closing hides it.
    private var setAsideForNothing: [(category: BudgetCategoryModel, amount: MinorUnits)] {
        hiddenCategories
            .map { (category: $0, amount: budget.setAsideForNothing(by: $0)) }
            .filter { $0.amount > 0 }
            .sorted { $0.category.displayName < $1.category.displayName }
    }

    private func release(_ amount: MinorUnits, from category: BudgetCategoryModel) {
        try? AssignmentWriter.adjustAssigned(by: -amount, category: category, month: .current(), in: modelContext)
        budget.refresh(in: modelContext)
    }

    private var unresolved: [LedgerTransaction] {
        let wanted = Set(budget.findings.uncategorisedBoundaryTransfers)
        guard !wanted.isEmpty else { return [] }
        return ((try? modelContext.fetch(
            FetchDescriptor<LedgerTransaction>(
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
        )) ?? []).filter { wanted.contains($0.identifier) }
    }
}

/// A finding, listed as each platform lists a transaction.
private struct FindingRow: View {
    let transaction: LedgerTransaction

    #if os(macOS)
    @Environment(BudgetModel.self) private var budget
    #endif

    var body: some View {
        #if os(iOS)
        TransactionRow(transaction: transaction, showsAccount: true)
        #else
        if transaction.isLive {
            let wording = TransactionWording(transaction: transaction)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(wording.title)
                    Text(verbatim: "\(wording.shortDate) · \(transaction.account?.name ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(budget.money(MinorUnits(transaction.amountMinor)))
                    .monospacedDigit()
                    .foregroundStyle(Flame.amountColor(MinorUnits(transaction.amountMinor)))
            }
            .contentShape(Rectangle())
        }
        #endif
    }
}
