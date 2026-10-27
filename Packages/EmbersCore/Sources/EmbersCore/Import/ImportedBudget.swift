import Foundation

public struct ImportedAccount: Identifiable, Sendable {
    public let id: EntityID
    public var name: String
    public var type: AccountType
    /// Drives FX-fee applicability on entry; inferred from a `(XXX)` suffix in the YNAB account name.
    public var currencyCode: String
    public var onBudget: Bool
    public var closed: Bool
    /// How the type and currency were guessed, surfaced in the dry-run screen for correction.
    public var inferenceNote: String
}

public struct ImportedPayee: Identifiable, Sendable {
    public let id: EntityID
    public var name: String
}

public struct ImportedCategoryGroup: Identifiable, Sendable {
    public let id: EntityID
    public var name: String
    public var order: Int
    public var hidden: Bool
}

public struct ImportedCategory: Identifiable, Sendable {
    public let id: EntityID
    public var name: String
    public var groupID: EntityID
    public var groupName: String
    public var kind: CategoryKind
    public var linkedAccountID: EntityID?
    public var hidden: Bool
    public var order: Int
}

/// One line of a split. YNAB lets each line carry its own payee, and a line can itself be a
/// transfer, so the line — not the parent — owns the payee and transfer link.
public struct ImportedSplitLine: Identifiable, Sendable {
    public let id: EntityID
    public var categoryID: EntityID?
    public var amount: MinorUnits
    public var memo: String
    public var payeeName: String
    public var payeeID: EntityID?
    public var transferCounterAccountID: EntityID?
    /// Shared with the row facing it, when this line is one side of a transfer.
    public var transferPairIdentifier: UUID?
}

public struct ImportedTransaction: Identifiable, Sendable {
    public let id: EntityID
    public var accountID: EntityID
    public var date: Date
    public var payeeID: EntityID?
    public var payeeName: String
    public var categoryID: EntityID?
    public var memo: String
    /// Signed total in base currency minor units; for splits, the sum of the split lines.
    public var amount: MinorUnits
    public var cleared: ClearedStatus
    public var flagName: String?
    public var transferCounterAccountID: EntityID?
    /// Shared by the two rows of one transfer, so each side can find the other once written.
    public var transferPairIdentifier: UUID?
    public var splits: [ImportedSplitLine]

    public var isSplit: Bool { !splits.isEmpty }
}

public struct ImportedAssignment: Sendable {
    public var categoryID: EntityID
    public var month: YearMonth
    public var amount: MinorUnits
}

/// A row of YNAB's own Plan.csv, kept as the expected output for verifying the budget engine.
public struct PlanExpectation: Sendable {
    public var month: YearMonth
    public var groupName: String
    public var categoryName: String
    public var categoryID: EntityID?
    public var assigned: MinorUnits
    public var activity: MinorUnits
    public var available: MinorUnits
}

public struct ImportReport: Sendable {
    public var accountCount = 0
    public var payeeCount = 0
    public var categoryGroupCount = 0
    public var categoryCount = 0
    public var transactionCount = 0
    public var splitTransactionCount = 0
    public var splitLineCount = 0
    public var transferPairCount = 0
    public var unmatchedTransferCount = 0
    public var assignmentCount = 0
    public var skippedRowCount = 0
    public var earliestDate: Date?
    public var latestDate: Date?
    /// When the export was produced. YNAB leaves transactions dated after this out of category
    /// activity, so reconciling against its figures has to use the same cutoff.
    public var sourceExportedAt: Date?
    public var firstMonth: YearMonth?
    public var lastMonth: YearMonth?
    public var warnings: [String] = []
}

public struct ImportedBudget: Sendable {
    public var baseCurrency: Currency
    public var accounts: [ImportedAccount]
    public var payees: [ImportedPayee]
    public var categoryGroups: [ImportedCategoryGroup]
    public var categories: [ImportedCategory]
    public var transactions: [ImportedTransaction]
    public var assignments: [ImportedAssignment]
    public var expectations: [PlanExpectation]
    public var report: ImportReport

    /// Flattens into engine input: split transactions contribute their lines, never a parent plus
    /// lines, so account balances and category activity are each counted exactly once.
    public func budgetInput() -> BudgetInput {
        let accounts = accounts.map {
            BudgetAccount(id: $0.id, name: $0.name, type: $0.type, onBudget: $0.onBudget, closed: $0.closed)
        }
        let categories = categories.map {
            BudgetCategory(
                id: $0.id,
                name: $0.name,
                groupName: $0.groupName,
                kind: $0.kind,
                linkedAccountID: $0.linkedAccountID,
                hidden: $0.hidden
            )
        }

        var entries: [BudgetEntry] = []
        entries.reserveCapacity(transactions.count + report.splitLineCount)
        for transaction in transactions {
            if transaction.isSplit {
                for line in transaction.splits {
                    entries.append(
                        BudgetEntry(
                            id: line.id,
                            accountID: transaction.accountID,
                            date: transaction.date,
                            categoryID: line.categoryID,
                            amount: line.amount,
                            transferCounterAccountID: line.transferCounterAccountID
                        )
                    )
                }
            } else {
                entries.append(
                    BudgetEntry(
                        id: transaction.id,
                        accountID: transaction.accountID,
                        date: transaction.date,
                        categoryID: transaction.categoryID,
                        amount: transaction.amount,
                        transferCounterAccountID: transaction.transferCounterAccountID
                    )
                )
            }
        }

        let assignments = assignments.map {
            BudgetAssignment(categoryID: $0.categoryID, month: $0.month, amount: $0.amount)
        }
        return BudgetInput(
            accounts: accounts,
            categories: categories,
            entries: entries,
            assignments: assignments
        )
    }
}
