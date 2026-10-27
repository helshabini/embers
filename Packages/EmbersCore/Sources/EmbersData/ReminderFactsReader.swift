import Foundation
import EmbersCore
import SwiftData

/// Reads what reminders are worked out from.
///
/// Run beside the recompute, on its background context and with its result, so planning reminders
/// costs the screen nothing: a handful of small fetches, each bounded.
public enum ReminderFactsReader {
    public static func read(
        from context: ModelContext,
        result: BudgetResult,
        asOf cutoff: Date,
        month: YearMonth,
        currency: Currency,
        lastBackupAt: Date?
    ) throws -> ReminderFacts {
        let accounts = try context.fetch(FetchDescriptor<Account>())
        guard !accounts.isEmpty else { return ReminderFacts(currency: currency, holdsAPlan: false) }

        let waiting = try context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.awaitsApproval == true && $0.parent == nil },
                sortBy: [SortDescriptor(\.date), SortDescriptor(\.createdAt)]
            )
        ).collapsingTransferPairs()
        let dueNow = waiting.filter { $0.date <= cutoff }.count
        let scheduled = waiting.filter { $0.date > cutoff }.map { entry in
            ReminderFacts.Scheduled(
                transactionID: entry.identifier,
                date: entry.date,
                name: name(of: entry),
                amount: MinorUnits(entry.amountMinor)
            )
        }

        return ReminderFacts(
            currency: currency,
            needsAttention: dueNow + result.uncategorized.count,
            scheduled: scheduled,
            shortfalls: try shortfalls(in: context, result: result, after: cutoff, month: month),
            cardsOwing: accounts
                .filter { $0.type.isCredit && !$0.closed && (result.accountBalances[$0.identifier] ?? 0) < 0 }
                .sorted { $0.order < $1.order }
                .map(\.name),
            unreconciled: try unreconciled(accounts.filter { !$0.closed }, in: context, asOf: cutoff),
            lastEntryAt: try lastEntry(in: context),
            lastBackupAt: lastBackupAt
        )
    }

    /// What a reminder calls an entry: the payee, else where a transfer goes, else its category.
    private static func name(of entry: LedgerTransaction) -> String {
        if let payee = entry.payee { return payee.displayName }
        if let counter = entry.transferCounterAccount {
            return entry.amountMinor < 0
                ? String(localized: "Transfer to \(counter.name)", bundle: .module)
                : String(localized: "Transfer from \(counter.name)", bundle: .module)
        }
        if let category = entry.category { return category.displayName }
        return entry.memo
    }

    /// Categories that hold less than what is scheduled out of them later this month, as the Plan
    /// colours them, each with the day the first of those payments falls.
    ///
    /// Split lines carry the category, so they are read too, not only parents.
    private static func shortfalls(
        in context: ModelContext,
        result: BudgetResult,
        after cutoff: Date,
        month: YearMonth
    ) throws -> [ReminderFacts.Shortfall] {
        let end = month.next.firstDay
        let coming = try context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.awaitsApproval == true && $0.date > cutoff && $0.date < end },
                sortBy: [SortDescriptor(\.date)]
            )
        )
        var firstDue: [UUID: Date] = [:]
        var categories: [UUID: BudgetCategoryModel] = [:]
        for entry in coming where entry.amountMinor < 0 {
            guard let category = entry.category, firstDue[category.identifier] == nil else { continue }
            firstDue[category.identifier] = entry.date
            categories[category.identifier] = category
        }
        return categories.values.compactMap { category in
            let status = CategoryStatus(
                result.state(of: category.identifier, in: month),
                upcoming: result.upcoming(of: category.identifier, in: month)
            )
            guard case let .underfunded(needed) = status, let date = firstDue[category.identifier] else { return nil }
            return ReminderFacts.Shortfall(
                categoryID: category.identifier, category: category.displayName, needed: needed, firstDue: date
            )
        }
        .sorted { $0.firstDue < $1.firstDue }
    }

    /// Each open account's oldest entry that has happened and is not reconciled.
    ///
    /// One bounded fetch per account rather than every unreconciled row: someone who never
    /// reconciles has thousands, and this runs on every recompute.
    private static func unreconciled(
        _ accounts: [Account],
        in context: ModelContext,
        asOf cutoff: Date
    ) throws -> [ReminderFacts.Unreconciled] {
        let reconciled = ClearedStatus.reconciled.rawValue
        return try accounts.compactMap { account in
            let accountID = account.identifier
            var oldest = FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate {
                    $0.account?.identifier == accountID && $0.parent == nil && $0.date <= cutoff
                        && $0.awaitsApproval == false && $0.clearedRaw != reconciled
                },
                sortBy: [SortDescriptor(\.date)]
            )
            oldest.fetchLimit = 1
            guard let entry = try context.fetch(oldest).first else { return nil }
            return ReminderFacts.Unreconciled(accountID: accountID, account: account.name, oldest: entry.date)
        }
    }

    private static func lastEntry(in context: ModelContext) throws -> Date? {
        var newest = FetchDescriptor<LedgerTransaction>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        newest.fetchLimit = 1
        return try context.fetch(newest).first?.createdAt
    }
}
