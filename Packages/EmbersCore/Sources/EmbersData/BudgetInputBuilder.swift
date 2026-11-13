import Foundation
import EmbersCore
import SwiftData

/// Reads the store into the value types `BudgetEngine` consumes.
///
/// The engine stays free of SwiftData so its rules can be checked without a store, and so the whole
/// budget can be recomputed from a plain snapshot.
public enum BudgetInputBuilder {
    /// - Parameter withPayees: whether to read who each entry was paid to. Only the reports want it,
    ///   and it is one more relationship to fault in for every entry on every recompute.
    public static func build(from context: ModelContext, withPayees: Bool = false) throws -> BudgetInput {
        let accounts = try context.fetch(FetchDescriptor<Account>())
        // One row per identifier. Two can share one until the sync merge folds them, and the engine
        // keys everything by it.
        let categories = Dictionary(grouping: try context.fetch(FetchDescriptor<BudgetCategoryModel>()), by: \.identifier)
            .values.map { SyncMerge.canonicalCategory($0) }
        let standing = Set(categories.map(\.persistentModelID))
        let assignments = try context.fetch(FetchDescriptor<CategoryAssignment>())
        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())
        let payees = withPayees ? try context.fetch(FetchDescriptor<Payee>()) : []

        return BudgetInput(
            accounts: accounts.map {
                BudgetAccount(
                    id: $0.identifier,
                    name: $0.name,
                    type: $0.type,
                    onBudget: $0.onBudget,
                    closed: $0.closed
                )
            },
            categories: categories.map {
                BudgetCategory(
                    id: $0.identifier,
                    name: $0.name,
                    groupName: $0.group?.name ?? "",
                    kind: $0.kind,
                    linkedAccountID: $0.linkedAccount?.identifier,
                    hidden: $0.hidden
                )
            },
            entries: transactions.compactMap { entry(for: $0, withPayee: withPayees) },
            assignments: assignments.compactMap { assignment in
                // Only the copy that stands for a category counts: another copy's rows are the same
                // money again, or are moved across when the merge runs.
                guard let category = assignment.category, standing.contains(category.persistentModelID) else {
                    return nil
                }
                let categoryID = category.identifier
                return BudgetAssignment(
                    categoryID: categoryID,
                    month: assignment.month,
                    amount: MinorUnits(assignment.amountMinor)
                )
            },
            payeeNames: Dictionary(payees.map { ($0.identifier, $0.name) }, uniquingKeysWith: { first, _ in first })
        )
    }

    /// Split parents are skipped: their lines carry the categories and together sum to the same
    /// amount, so counting both would double every split.
    private static func entry(for transaction: LedgerTransaction, withPayee: Bool) -> BudgetEntry? {
        guard let accountID = transaction.account?.identifier else { return nil }
        guard !transaction.isSplitParent else { return nil }
        return BudgetEntry(
            id: transaction.identifier,
            accountID: accountID,
            date: transaction.date,
            categoryID: transaction.category?.identifier,
            amount: MinorUnits(transaction.amountMinor),
            transferCounterAccountID: transaction.transferCounterAccount?.identifier,
            // A split's lines are approved with their parent, which is the row the person sees.
            awaitsApproval: transaction.awaitsApproval || transaction.parent?.awaitsApproval == true,
            // A split's lines are usually left without a payee of their own; the parent's is theirs.
            payeeID: withPayee ? (transaction.payee ?? transaction.parent?.payee)?.identifier : nil
        )
    }
}
