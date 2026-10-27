import Foundation
import EmbersCore
import SwiftData

/// Creates accounts, with the pieces YNAB creates alongside one.
///
/// An account is never just a row. A starting balance is a real transaction against
/// `Inflow: Ready to Assign` — that is how the export records it, including for cards, whose opening
/// debt is an outflow from what there is to assign. A credit account also needs its payment category,
/// because the engine's carryover rules key off that category existing.
@MainActor
public enum AccountWriter {
    /// Adds an account and everything that has to exist with it.
    ///
    /// - Parameter startingBalanceMinor: signed, in the plan's currency. Negative opens a card in
    ///   debt. Zero writes no opening transaction at all, rather than a row reading $0.00.
    @discardableResult
    public static func create(
        name: String,
        type: AccountType,
        currencyCode: String,
        onBudget: Bool? = nil,
        fxFeePercentOverride: Double? = nil,
        startingBalanceMinor: Int = 0,
        startingDate: Date = .endOfBudgetDay(),
        in context: ModelContext
    ) throws -> Account {
        let account = Account(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            type: type,
            currencyCode: currencyCode,
            fxFeePercentOverride: fxFeePercentOverride,
            onBudget: onBudget,
            order: try nextOrder(in: context)
        )
        context.insert(account)

        if type.isCredit {
            try ensurePaymentCategory(for: account, in: context)
        }
        if startingBalanceMinor != 0 {
            try writeStartingBalance(
                startingBalanceMinor, for: account, on: startingDate, in: context
            )
        }

        try context.save()
        return account
    }

    /// Where a new account sits: after the ones already there.
    private static func nextOrder(in context: ModelContext) throws -> Int {
        let existing = try context.fetch(FetchDescriptor<Account>())
        return (existing.map(\.order).max() ?? -1) + 1
    }

    /// The opening entry, recorded the way the YNAB export records it.
    private static func writeStartingBalance(
        _ amountMinor: Int,
        for account: Account,
        on date: Date,
        in context: ModelContext
    ) throws {
        let transaction = LedgerTransaction(
            date: date,
            amountMinor: amountMinor,
            // Reconciled, because an opening balance is by definition what the statement said.
            cleared: .reconciled,
            account: account,
            payee: try startingBalancePayee(in: context),
            // Tracking accounts sit outside the budget, so their opening balance is uncategorised.
            category: account.onBudget ? try inflowCategory(in: context) : nil
        )
        context.insert(transaction)
    }

    private static func startingBalancePayee(in context: ModelContext) throws -> Payee {
        let name = "Starting Balance"
        if let existing = try context.fetch(FetchDescriptor<Payee>())
            .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let created = Payee(name: name, lastUsedAt: Date())
        context.insert(created)
        return created
    }

    /// The single internal inflow bucket, created with its group if the plan has none yet — which is
    /// the case when the first account is added without importing anything.
    public static func inflowCategory(in context: ModelContext) throws -> BudgetCategoryModel {
        let categories = try context.fetch(FetchDescriptor<BudgetCategoryModel>())
        if let existing = categories.first(where: { $0.kind == .inflowReadyToAssign }) {
            return existing
        }
        let group = try group(named: "Inflow", systemManaged: true, in: context)
        let created = BudgetCategoryModel(
            name: "Ready to Assign", group: group, kind: .inflowReadyToAssign
        )
        context.insert(created)
        return created
    }

    /// A credit account's payment category: one per card, named after it, as YNAB does.
    ///
    /// The name matters — the importer identifies cards by matching payment categories back to
    /// account names, so a card added here has to look like a card that was imported.
    @discardableResult
    public static func ensurePaymentCategory(
        for account: Account,
        in context: ModelContext
    ) throws -> BudgetCategoryModel {
        let categories = try context.fetch(FetchDescriptor<BudgetCategoryModel>())
        if let existing = categories.first(where: {
            $0.kind == .creditCardPayment && $0.linkedAccount?.identifier == account.identifier
        }) {
            existing.name = account.name
            return existing
        }
        let group = try group(named: "Credit Card Payments", systemManaged: true, in: context)
        let created = BudgetCategoryModel(
            name: account.name,
            group: group,
            order: (group.categories?.map(\.order).max() ?? -1) + 1,
            kind: .creditCardPayment,
            linkedAccount: account
        )
        context.insert(created)
        return created
    }

    private static func group(
        named name: String,
        systemManaged: Bool,
        in context: ModelContext
    ) throws -> CategoryGroup {
        let groups = try context.fetch(FetchDescriptor<CategoryGroup>())
        if let existing = groups.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let created = CategoryGroup(
            name: name,
            order: (groups.map(\.order).max() ?? -1) + 1,
            isSystemManaged: systemManaged
        )
        context.insert(created)
        return created
    }
}
