import Foundation
import EmbersCore
import SwiftData

/// Looks for the handful of things that can leave a budget quietly wrong.
///
/// Not a general health check: each of these is a specific way earlier versions of the app, or an
/// import, could write something the plan then misreads. Two of them can be put right without
/// guessing, and are. The third cannot — only the person knows which envelope the money belongs to —
/// so it is reported rather than decided.
@MainActor
public enum BudgetAudit {
    public struct Findings: Sendable, Equatable {
        /// Transfers across the edge of the budget carrying no category, so the money arrives or
        /// leaves without the plan accounting for it against anything.
        public var uncategorisedBoundaryTransfers: [UUID] = []
        /// Transfer rows whose other half the app could not find.
        public var unpairedTransfers: Int = 0

        public init() {}

        public var isClear: Bool {
            uncategorisedBoundaryTransfers.isEmpty && unpairedTransfers == 0
        }
    }

    public struct Repairs: Sendable, Equatable {
        /// Categories found on the tracked side of a boundary transfer and moved to the budget side.
        public var categoriesMovedToBudgetSide = 0
        /// Categories found on a tracked account's own entries and cleared, since a tracked account
        /// is outside the plan and a category there counts for nothing.
        public var strayCategoriesCleared = 0
        public var transfersPaired = 0
        public var creditCardCategoriesChanged = 0
        /// Entries dated with an instant rather than a day, moved to midday UTC of the local day.
        public var datesMovedToBudgetDay = 0
        /// What two devices each made for themselves, folded into one.
        public var duplicatesMerged = SyncMerge.Merges()

        public init() {}

        public var didChangeAnything: Bool {
            categoriesMovedToBudgetSide + strayCategoriesCleared
                + transfersPaired + creditCardCategoriesChanged + datesMovedToBudgetDay > 0
                || duplicatesMerged.didChangeAnything
        }
    }

    /// Puts right everything that can be put right without a decision.
    @discardableResult
    public static func repair(
        in context: ModelContext,
        timeZone: TimeZone = .current
    ) throws -> Repairs {
        var repairs = Repairs()
        // First, so the card categories below are brought in step with one group, not two.
        repairs.duplicatesMerged = try SyncMerge.mergeDuplicates(in: context)
        repairs.datesMovedToBudgetDay = try moveDatesToBudgetDays(in: context, timeZone: timeZone)
        repairs.transfersPaired = try TransferWriter.repairUnpairedTransfers(in: context)

        let cardChange = try CategoryWriter.syncCreditCardCategories(in: context)
        repairs.creditCardCategoriesChanged =
            cardChange.added + cardChange.hidden + cardChange.restored + cardChange.renamed

        // A category sitting on a tracked account's row. On one half of a boundary transfer it
        // belongs on the other half; anywhere else it is simply not the plan's business.
        for transaction in try trackedEntriesCarryingACategory(in: context) {
            guard let category = transaction.category else { continue }
            if transaction.isTransfer,
               let sides = try? TransferWriter.pair(of: transaction, in: context),
               let budgetSide = sides.first(where: { $0.account?.onBudget == true }) {
                if budgetSide.category == nil {
                    budgetSide.category = category
                    repairs.categoriesMovedToBudgetSide += 1
                } else {
                    repairs.strayCategoriesCleared += 1
                }
            } else {
                repairs.strayCategoriesCleared += 1
            }
            transaction.category = nil
        }

        if context.hasChanges { try context.save() }
        return repairs
    }

    /// Puts every date back at midday UTC, on the local day it was entered.
    ///
    /// Before the editor dated entries by the local day, it saved the instant of tapping Save. At
    /// UTC+4 anything entered after 8 pm landed on the next UTC day — 35 entries in the real budget
    /// on 30 Sep alone, three of them counted in September though entered on 1 October. A schedule
    /// started from one carried its time into every later occurrence. The local day of that instant
    /// is the day the person was having, so there is nothing to guess. Runs before pairing, which
    /// matches the two sides of a transfer by date.
    private static func moveDatesToBudgetDays(
        in context: ModelContext,
        timeZone: TimeZone
    ) throws -> Int {
        var moved = 0
        for transaction in try context.fetch(FetchDescriptor<LedgerTransaction>())
        where !transaction.date.isBudgetDay {
            transaction.date = transaction.date.asBudgetDay(in: timeZone)
            moved += 1
        }
        return moved
    }

    /// What is left that needs a person.
    public static func findings(in context: ModelContext) throws -> Findings {
        var findings = Findings()
        for transaction in try boundaryTransfers(in: context) {
            guard let sides = try? TransferWriter.pair(of: transaction, in: context) else { continue }
            let budgetSide = sides.first { $0.account?.onBudget == true }
            if budgetSide?.category == nil, let budgetSide {
                findings.uncategorisedBoundaryTransfers.append(budgetSide.identifier)
            }
        }
        findings.uncategorisedBoundaryTransfers = Array(Set(findings.uncategorisedBoundaryTransfers))

        findings.unpairedTransfers = try context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.transferPairIdentifier == nil }
            )
        ).filter { $0.isTransfer && !$0.isSplitParent }.count

        return findings
    }

    /// Every transfer row whose two accounts sit on opposite sides of the budget.
    private static func boundaryTransfers(in context: ModelContext) throws -> [LedgerTransaction] {
        // Narrowed in memory: a predicate cannot ask whether a relationship is set.
        try context.fetch(FetchDescriptor<LedgerTransaction>()).filter { transaction in
            guard !transaction.isSplitParent,
                  let here = transaction.account,
                  let there = transaction.transferCounterAccount
            else { return false }
            return here.onBudget != there.onBudget
        }
    }

    private static func trackedEntriesCarryingACategory(
        in context: ModelContext
    ) throws -> [LedgerTransaction] {
        try context.fetch(FetchDescriptor<LedgerTransaction>())
            .filter { $0.category != nil && $0.account?.onBudget == false }
    }
}
