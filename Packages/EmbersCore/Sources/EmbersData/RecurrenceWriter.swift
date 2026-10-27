import Foundation
import EmbersCore
import SwiftData

/// Keeps scheduled transactions moving forward.
///
/// Anything dated after today is scheduled, and awaits approval. When its date arrives it still counts
/// for nothing until the person approves it — the payment may have been cancelled — and approving a
/// repeating one dates a fresh copy to the following occurrence. Only the next occurrence exists at
/// any time, so the register never fills with rows nobody has confirmed.
@MainActor
public enum RecurrenceWriter {
    /// Marks everything dated after `asOf` as awaiting approval.
    ///
    /// Done here rather than at each place an entry is written — the editor, transfers, an import, a
    /// restore — because any of them can produce a future date, and one missed would let that entry
    /// count on its day without anyone confirming it. A scalar predicate over a few future rows, so
    /// cheap enough to run on every refresh.
    @discardableResult
    public static func markScheduled(
        in context: ModelContext,
        asOf: Date = .endOfBudgetDay()
    ) throws -> Int {
        let unmarked = try context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.date > asOf && $0.awaitsApproval == false }
            )
        )
        for transaction in unmarked { transaction.awaitsApproval = true }
        if !unmarked.isEmpty { try context.save() }
        return unmarked.count
    }

    /// Scheduled entries whose day has come, oldest first, each transfer once.
    public static func dueForApproval(
        in context: ModelContext,
        asOf: Date = .endOfBudgetDay()
    ) throws -> [LedgerTransaction] {
        try context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate {
                    $0.awaitsApproval == true && $0.date <= asOf && $0.parent == nil
                },
                sortBy: [SortDescriptor(\.date), SortDescriptor(\.createdAt)]
            )
        ).collapsingTransferPairs()
    }

    /// Confirms a scheduled entry happened: it starts to count, and a repeat moves to the next one.
    ///
    /// The next occurrence is the one straight after this, not after today. If several were missed,
    /// each waits its turn, since each is a payment that may or may not have gone out.
    public static func approve(_ transaction: LedgerTransaction, in context: ModelContext) throws {
        try settle(transaction, in: context)
        try context.save()
    }

    /// Approves everything due.
    ///
    /// - Returns: How many entries were approved, counting a transfer once.
    @discardableResult
    public static func approveDue(
        in context: ModelContext,
        asOf: Date = .endOfBudgetDay()
    ) throws -> Int {
        let due = try dueForApproval(in: context, asOf: asOf)
        for transaction in due { try settle(transaction, in: context) }
        if !due.isEmpty { try context.save() }
        return due.count
    }

    /// Passes over one occurrence of a repeat without entering it: the payment did not go out this
    /// time. The schedule moves to the following date. Something that does not repeat has no
    /// following date, so skipping it removes it.
    public static func skip(_ transaction: LedgerTransaction, in context: ModelContext) throws {
        let sides = try TransferWriter.pair(of: transaction, in: context)
        guard let rule = sides.lazy.compactMap(\.recurrence).first else {
            try TransactionWriter.delete(transaction, in: context)
            return
        }
        let next = rule.nextDate(after: transaction.date)
        for side in sides {
            side.date = next
            for line in side.splitLines ?? [] { line.date = next }
        }
        try context.save()
    }

    /// Whether skipping this moves it on or removes it. A transfer's rule may be on its other side.
    public static func repeats(_ transaction: LedgerTransaction, in context: ModelContext) -> Bool {
        transaction.recurrence != nil
            || ((try? TransferWriter.pair(of: transaction, in: context)) ?? []).contains { $0.recurrence != nil }
    }

    /// Approves one entry, both sides of a transfer and the lines of a split with it, without saving.
    private static func settle(_ transaction: LedgerTransaction, in context: ModelContext) throws {
        let sides = try TransferWriter.pair(of: transaction, in: context)
        for side in sides {
            side.awaitsApproval = false
            for line in side.splitLines ?? [] { line.awaitsApproval = false }
        }
        // Only one side of a repeating transfer carries the rule.
        guard let ruled = sides.first(where: { $0.recurrence != nil }), let rule = ruled.recurrence
        else { return }
        ruled.recurrence = nil
        try enterNextOccurrence(after: ruled, rule: rule, on: rule.nextDate(after: ruled.date), in: context)
    }

    /// Moves the rule off entries that carry one but have already happened.
    ///
    /// A repeat set on a day that has been — "I paid this today, and it repeats monthly" — is entered
    /// as it is, and the schedule continues from the next date after today. Entries awaiting approval
    /// are not touched: they move on only when approved.
    ///
    /// - Returns: How many occurrences were entered.
    @discardableResult
    public static func advanceDueOccurrences(
        in context: ModelContext,
        asOf: Date = .endOfBudgetDay()
    ) throws -> Int {
        // SwiftData cannot build a predicate against the optional enum, so the date narrows the
        // fetch and the rule is checked in memory.
        let due = try context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.date <= asOf && $0.awaitsApproval == false }
            )
        ).filter { $0.recurrence != nil }

        for transaction in due {
            guard let rule = transaction.recurrence else { continue }
            let next = rule.nextDate(after: transaction.date, notBefore: asOf)

            // The occurrence that has arrived becomes a plain transaction.
            transaction.recurrence = nil
            try enterNextOccurrence(after: transaction, rule: rule, on: next, in: context)
        }

        if !due.isEmpty { try context.save() }
        return due.count
    }

    /// Copies a transaction forward to its next date, carrying the rule with it.
    ///
    /// A transfer is copied from the real pair rather than rebuilt from one side. The two sides are
    /// not mirror images: a transfer into a tracking account leaves the budget, so the budget side
    /// carries a category — a mortgage payment is `Debt Payments: Mortgage` — while the tracking side
    /// carries none. Synthesising the counterpart dropped that category, and a repeating mortgage
    /// quietly stopped being budgeted for after its first occurrence.
    private static func enterNextOccurrence(
        after transaction: LedgerTransaction,
        rule: Recurrence,
        on date: Date,
        in context: ModelContext
    ) throws {
        let next = copy(of: transaction, on: date, in: context)
        next.recurrence = rule

        guard transaction.isTransfer, let destination = transaction.transferCounterAccount else {
            return
        }

        let pairIdentifier = UUID()
        next.transferPairIdentifier = pairIdentifier

        let counterpart = try TransferWriter.pair(of: transaction, in: context)
            .first { $0.identifier != transaction.identifier }

        let other: LedgerTransaction
        if let counterpart {
            other = copy(of: counterpart, on: date, in: context)
        } else {
            // The other side has gone missing. Rebuild what can be known, rather than leave money
            // arriving from nowhere.
            other = LedgerTransaction(
                date: date,
                amountMinor: -transaction.amountMinor,
                memo: transaction.memo,
                account: destination,
                transferCounterAccount: transaction.account
            )
            other.occurrenceOf = transaction.identifier
            context.insert(other)
        }
        other.transferPairIdentifier = pairIdentifier
    }

    /// The same entry on a later day, not yet confirmed.
    private static func copy(
        of transaction: LedgerTransaction,
        on date: Date,
        in context: ModelContext
    ) -> LedgerTransaction {
        let copied = LedgerTransaction(
            date: date,
            amountMinor: transaction.amountMinor,
            memo: transaction.memo,
            flag: transaction.flag,
            account: transaction.account,
            payee: transaction.payee,
            category: transaction.category,
            transferCounterAccount: transaction.transferCounterAccount,
            conversion: transaction.conversion
        )
        // A scheduled entry has not happened yet, so it starts unreconciled however this one ended,
        // and waits to be approved even if its date has already come.
        copied.cleared = .uncleared
        copied.awaitsApproval = true
        copied.occurrenceOf = transaction.identifier
        context.insert(copied)
        return copied
    }

    /// Stops a transaction repeating, leaving it as a one-off.
    public static func stopRepeating(_ transaction: LedgerTransaction, in context: ModelContext) throws {
        transaction.recurrence = nil
        try context.save()
    }
}
