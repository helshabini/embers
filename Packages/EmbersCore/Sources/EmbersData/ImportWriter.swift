import Foundation
import EmbersCore
import SwiftData

/// Writes an imported budget into the store.
///
/// Identifiers are carried over from the import so the engine's output can be traced back to the rows
/// it came from, and so a dry run and the real write describe the same objects.
public enum ImportWriter {
    @discardableResult
    public static func write(_ budget: ImportedBudget, into context: ModelContext) throws -> PlanSettings {
        let settings = try context.planSettings()
        settings.baseCurrencyCode = budget.baseCurrency.code

        var accountsByID: [EntityID: Account] = [:]
        for (index, imported) in budget.accounts.enumerated() {
            let account = Account(
                identifier: imported.id,
                name: imported.name,
                type: imported.type,
                currencyCode: imported.currencyCode,
                onBudget: imported.onBudget,
                closed: imported.closed,
                order: index,
                notes: imported.inferenceNote
            )
            context.insert(account)
            accountsByID[imported.id] = account
        }

        var payeesByID: [EntityID: Payee] = [:]
        for imported in budget.payees {
            let payee = Payee(identifier: imported.id, name: imported.name)
            context.insert(payee)
            payeesByID[imported.id] = payee
        }

        var groupsByID: [EntityID: CategoryGroup] = [:]
        for imported in budget.categoryGroups {
            let group = CategoryGroup(
                identifier: imported.id,
                name: imported.name,
                order: imported.order,
                hidden: imported.hidden,
                isSystemManaged: imported.name == "Credit Card Payments"
            )
            context.insert(group)
            groupsByID[imported.id] = group
        }

        var categoriesByID: [EntityID: BudgetCategoryModel] = [:]
        for imported in budget.categories {
            let category = BudgetCategoryModel(
                identifier: imported.id,
                name: imported.name,
                group: groupsByID[imported.groupID],
                order: imported.order,
                hidden: imported.hidden,
                kind: imported.kind,
                linkedAccount: imported.linkedAccountID.flatMap { accountsByID[$0] }
            )
            context.insert(category)
            categoriesByID[imported.id] = category
        }

        for imported in budget.assignments {
            guard let category = categoriesByID[imported.categoryID] else { continue }
            context.insert(
                CategoryAssignment(
                    month: imported.month,
                    amountMinor: Int(imported.amount),
                    category: category
                )
            )
        }

        for imported in budget.transactions {
            guard let account = accountsByID[imported.accountID] else { continue }
            let transaction = LedgerTransaction(
                identifier: imported.id,
                date: imported.date,
                amountMinor: Int(imported.amount),
                memo: imported.memo,
                cleared: imported.cleared,
                flag: imported.flagName.flatMap { FlagColor(rawValue: $0.lowercased()) },
                account: account,
                payee: imported.payeeID.flatMap { payeesByID[$0] },
                category: imported.categoryID.flatMap { categoriesByID[$0] },
                transferCounterAccount: imported.transferCounterAccountID.flatMap { accountsByID[$0] },
                importKey: "ynab-csv"
            )
            transaction.transferPairIdentifier = imported.transferPairIdentifier
            context.insert(transaction)

            // Lines repeat the parent's account so each is a complete register entry on its own.
            for line in imported.splits {
                let lineTransaction = LedgerTransaction(
                    identifier: line.id,
                    date: imported.date,
                    amountMinor: Int(line.amount),
                    memo: line.memo,
                    cleared: imported.cleared,
                    account: account,
                    payee: line.payeeID.flatMap { payeesByID[$0] },
                    category: line.categoryID.flatMap { categoriesByID[$0] },
                    transferCounterAccount: line.transferCounterAccountID.flatMap { accountsByID[$0] },
                    parent: transaction,
                    importKey: "ynab-csv"
                )
                lineTransaction.transferPairIdentifier = line.transferPairIdentifier
                context.insert(lineTransaction)
            }
        }

        try context.save()
        return settings
    }

    /// Deletes every plan object, leaving settings in place. Used by Start Fresh once a backup exists.
    ///
    /// One object at a time rather than `delete(model:)`. SwiftData does not say whether that bulk
    /// delete reaches CloudKit, and if it does not, every other device keeps the old plan and the
    /// restore lands beside it. Deleting each object is the path syncing certainly sees.
    public static func deleteAllPlanData(in context: ModelContext) throws {
        try deleteEach(LedgerTransaction.self, in: context)
        try deleteEach(CategoryAssignment.self, in: context)
        try deleteEach(BudgetCategoryModel.self, in: context)
        try deleteEach(CategoryGroup.self, in: context)
        try deleteEach(Payee.self, in: context)
        try deleteEach(Account.self, in: context)
        try context.save()
    }

    private static func deleteEach<Model: PersistentModel>(
        _ type: Model.Type,
        in context: ModelContext
    ) throws {
        for object in try context.fetch(FetchDescriptor<Model>()) {
            context.delete(object)
        }
    }
}
