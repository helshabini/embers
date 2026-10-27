import Foundation
import EmbersCore
import SwiftData

/// Reconciling an account against its statement.
///
/// The flow YNAB uses: say what the bank says the balance is, tick off what has actually cleared, and
/// if the two still disagree the app writes one adjustment so they do. Everything cleared up to that
/// point is then locked as reconciled, which is the marker that says "checked against a statement,
/// do not quietly change".
@MainActor
public enum ReconcileWriter {
    /// What reconciling would do, before anything is written.
    public struct Plan: Sendable, Equatable {
        /// What the app currently thinks has cleared.
        public let clearedBalanceMinor: Int
        /// What the statement says.
        public let statementBalanceMinor: Int
        /// Statement minus cleared: the adjustment that would be written, if any.
        public let differenceMinor: Int
        /// How many rows would be locked as reconciled.
        public let rowsToLock: Int

        public var needsAdjustment: Bool { differenceMinor != 0 }

        /// The same account against another statement figure, without reading the store again.
        public func comparing(to statementBalanceMinor: Int) -> Plan {
            Plan(
                clearedBalanceMinor: clearedBalanceMinor,
                statementBalanceMinor: statementBalanceMinor,
                differenceMinor: statementBalanceMinor - clearedBalanceMinor,
                rowsToLock: rowsToLock
            )
        }

        public init(
            clearedBalanceMinor: Int,
            statementBalanceMinor: Int,
            differenceMinor: Int,
            rowsToLock: Int
        ) {
            self.clearedBalanceMinor = clearedBalanceMinor
            self.statementBalanceMinor = statementBalanceMinor
            self.differenceMinor = differenceMinor
            self.rowsToLock = rowsToLock
        }
    }

    /// Works out what reconciling to `statementBalanceMinor` would involve, changing nothing.
    public static func plan(
        for account: Account,
        statementBalanceMinor: Int,
        asOf: Date = .endOfBudgetDay(),
        in context: ModelContext
    ) throws -> Plan {
        let settled = try settledRows(of: account, asOf: asOf, in: context)
        let cleared = settled.reduce(0) { $0 + $1.amountMinor }
        return Plan(
            clearedBalanceMinor: cleared,
            statementBalanceMinor: statementBalanceMinor,
            differenceMinor: statementBalanceMinor - cleared,
            rowsToLock: settled.filter { $0.cleared != .reconciled }.count
        )
    }

    /// Reconciles the account: writes the adjustment if one is needed, then locks what has cleared.
    ///
    /// - Returns: the adjustment that was written, or `nil` when the statement already agreed.
    @discardableResult
    public static func reconcile(
        _ account: Account,
        statementBalanceMinor: Int,
        asOf: Date = .endOfBudgetDay(),
        in context: ModelContext
    ) throws -> LedgerTransaction? {
        let plan = try plan(
            for: account, statementBalanceMinor: statementBalanceMinor, asOf: asOf, in: context
        )

        var adjustment: LedgerTransaction?
        if plan.needsAdjustment {
            let transaction = LedgerTransaction(
                date: asOf,
                amountMinor: plan.differenceMinor,
                // Written in the reader's language: a memo is a note, not something looked up again.
                memo: String(localized: "Reconciliation adjustment", bundle: .module),
                cleared: .reconciled,
                account: account,
                payee: try reconciliationPayee(in: context),
                // An unexplained difference is real money in or out of the budget, so it goes to
                // Ready to Assign rather than quietly changing a spending category's activity.
                category: account.onBudget ? try AccountWriter.inflowCategory(in: context) : nil
            )
            transaction.reconciliationKey = [
                account.identifier.uuidString,
                String(Int(asOf.timeIntervalSinceReferenceDate)),
                String(plan.statementBalanceMinor),
                String(plan.clearedBalanceMinor),
            ].joined(separator: ":")
            context.insert(transaction)
            adjustment = transaction
        }

        // Lock everything that has cleared, the adjustment included.
        for row in try settledRows(of: account, asOf: asOf, in: context) {
            row.cleared = .reconciled
        }

        try context.save()
        return adjustment
    }

    /// The rows a statement covers: cleared or already reconciled, and not in the future.
    ///
    /// Uncleared rows are deliberately excluded — they are the ones the bank has not seen yet, and
    /// the whole point of the cleared balance is that it leaves them out.
    private static func settledRows(
        of account: Account,
        asOf: Date,
        in context: ModelContext
    ) throws -> [LedgerTransaction] {
        let identifier = account.identifier
        let rows = try context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.date <= asOf && $0.account?.identifier == identifier }
            )
        )
        // Split parents are skipped, exactly as the engine skips them: their lines carry the money,
        // and counting both would double every split. Nor can a statement show what has not been
        // approved: it has not happened.
        return rows.filter {
            $0.cleared != .uncleared && !$0.isSplitParent
                && !$0.awaitsApproval && $0.parent?.awaitsApproval != true
        }
    }

    private static func reconciliationPayee(in context: ModelContext) throws -> Payee {
        let name = "Reconciliation Balance Adjustment"
        if let existing = try context.fetch(FetchDescriptor<Payee>())
            .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let created = Payee(name: name, lastUsedAt: Date())
        context.insert(created)
        return created
    }
}
