import Foundation
import EmbersCore
import SwiftData

/// Creates and removes transfers between accounts.
///
/// A transfer is two entries, not one: money leaving one register and arriving in another. Each side
/// is a real row in its own account, which is why both must be written and deleted together — a
/// half-deleted transfer would leave money that came from nowhere.
@MainActor
public enum TransferWriter {
    @discardableResult
    public static func makeTransfer(
        amountMinor: Int,
        from source: Account,
        to destination: Account,
        date: Date,
        memo: String = "",
        cleared: ClearedStatus = .uncleared,
        category: BudgetCategoryModel? = nil,
        conversion: CurrencyConversion? = nil,
        recurrence: Recurrence? = nil,
        in context: ModelContext
    ) -> (outgoing: LedgerTransaction, incoming: LedgerTransaction) {
        let magnitude = abs(amountMinor)
        let pairIdentifier = UUID()

        // A transfer across the edge of the budget is categorised, and the category belongs to the
        // side inside the budget — only that side is money the plan can see. Putting it on both
        // would count the same movement as an inflow and an outflow, which cancel to nothing.
        let budgetSideIsSource = source.onBudget || !destination.onBudget

        let outgoing = LedgerTransaction(
            date: date,
            amountMinor: -magnitude,
            memo: memo,
            cleared: cleared,
            account: source,
            category: budgetSideIsSource ? category : nil,
            transferCounterAccount: destination,
            conversion: conversion
        )
        outgoing.transferPairIdentifier = pairIdentifier
        // Only the outgoing side repeats. `RecurrenceWriter` rebuilds both sides from whichever one
        // carries the rule, so putting it on both would enter every occurrence twice.
        outgoing.recurrence = recurrence

        let incoming = LedgerTransaction(
            date: date,
            amountMinor: magnitude,
            memo: memo,
            cleared: cleared,
            account: destination,
            category: budgetSideIsSource ? nil : category,
            transferCounterAccount: source
        )
        incoming.transferPairIdentifier = pairIdentifier

        context.insert(outgoing)
        context.insert(incoming)
        return (outgoing, incoming)
    }

    /// Deletes both sides of a transfer, given either one.
    public static func deleteTransfer(_ transaction: LedgerTransaction, in context: ModelContext) throws {
        for side in try pair(of: transaction, in: context) {
            context.delete(side)
        }
        try context.save()
    }

    /// Both rows of a transfer, or just the one passed in when it is not a transfer.
    /// Ties together transfer rows that were written without a pair identifier.
    ///
    /// The importer matched transfer rows to count them for its report and then wrote them as two
    /// unrelated entries, so every imported transfer was two rows that did not know about each other:
    /// deleting one left the other behind, and editing one did not move the other. This repairs them
    /// in place, and finds nothing on a budget that has already been repaired.
    ///
    /// - Returns: how many pairs were tied together.
    @discardableResult
    public static func repairUnpairedTransfers(in context: ModelContext) throws -> Int {
        // Narrowed to transfers that are actually loose. Asking only for rows with no pair
        // identifier would hand back every ordinary transaction in the budget — ten thousand of
        // them — to find the handful that are transfers, on every launch.
        let loose = try context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate {
                    $0.transferPairIdentifier == nil && $0.transferCounterAccount != nil
                }
            )
        ).filter { !$0.isSplitParent }
        guard !loose.isEmpty else { return 0 }

        /// What both sides of one transfer agree on: the two accounts, the day, and the magnitude.
        struct Key: Hashable {
            let accounts: [UUID]
            let day: Date
            let magnitude: Int
        }

        var waiting: [Key: [LedgerTransaction]] = [:]
        var paired = 0

        for transaction in loose {
            guard let account = transaction.account?.identifier,
                  let counter = transaction.transferCounterAccount?.identifier
            else { continue }
            let key = Key(
                accounts: [account, counter].sorted { $0.uuidString < $1.uuidString },
                day: transaction.date,
                magnitude: abs(transaction.amountMinor)
            )

            // The match is the row facing the other way between the same two accounts.
            if let index = waiting[key]?.firstIndex(where: {
                $0.amountMinor == -transaction.amountMinor
                    && $0.account?.identifier == counter
            }) {
                let counterpart = waiting[key]!.remove(at: index)
                let identifier = UUID()
                transaction.transferPairIdentifier = identifier
                counterpart.transferPairIdentifier = identifier
                paired += 1
            } else {
                waiting[key, default: []].append(transaction)
            }
        }

        if paired > 0 { try context.save() }
        return paired
    }

    public static func pair(
        of transaction: LedgerTransaction,
        in context: ModelContext
    ) throws -> [LedgerTransaction] {
        guard let pairIdentifier = transaction.transferPairIdentifier else { return [transaction] }
        return try context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.transferPairIdentifier == pairIdentifier }
            )
        )
    }

    /// Keeps the other side of a transfer in step after one side is edited.
    ///
    /// - Parameter destination: Where the money should now go. Passing it moves the counterpart to
    ///   that account, which is the only way to redirect a transfer without deleting it: the
    ///   counterpart lives in the old account's register and has to move, not just be relabelled.
    /// Puts a transfer's category on the side the budget can see, and clears the other.
    ///
    /// A transfer across the edge of the budget carries one category between the two rows. Carried
    /// on both, the same movement counts once as money arriving and once as money leaving, and the
    /// two cancel: a withdrawal from a certificate of deposit would reach the budget as nothing at
    /// all.
    public static func placeCategory(
        _ category: BudgetCategoryModel?,
        onBudgetSideOf transaction: LedgerTransaction,
        in context: ModelContext
    ) throws {
        let sides = try pair(of: transaction, in: context)
        guard let budgetSide = sides.first(where: { $0.account?.onBudget == true }) else {
            // Neither side is on the budget; nothing here is the plan's business.
            for side in sides { side.category = nil }
            try context.save()
            return
        }
        budgetSide.category = category
        for side in sides where side.identifier != budgetSide.identifier {
            side.category = nil
        }
        try context.save()
    }

    public static func syncCounterpart(
        of transaction: LedgerTransaction,
        destination: Account? = nil,
        in context: ModelContext
    ) throws {
        let sides = try pair(of: transaction, in: context)
        guard sides.count == 2,
              let counterpart = sides.first(where: { $0.identifier != transaction.identifier })
        else { return }

        if let destination, destination.identifier != counterpart.account?.identifier {
            counterpart.account = destination
            transaction.transferCounterAccount = destination
            counterpart.transferCounterAccount = transaction.account
        }

        counterpart.date = transaction.date
        counterpart.memo = transaction.memo
        counterpart.amountMinor = -transaction.amountMinor
        counterpart.cleared = transaction.cleared
        try context.save()
    }

    /// The account on the other side of a transfer, if there is one.
    public static func counterpartAccount(
        of transaction: LedgerTransaction,
        in context: ModelContext
    ) throws -> Account? {
        let sides = try pair(of: transaction, in: context)
        return sides.first { $0.identifier != transaction.identifier }?.account
            ?? transaction.transferCounterAccount
    }
}
