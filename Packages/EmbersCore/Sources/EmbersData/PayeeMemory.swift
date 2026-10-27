import Foundation
import EmbersCore
import SwiftData

/// Remembers which category a payee usually belongs to.
///
/// The supermarket is nearly always groceries. Pre-filling from the last time saves choosing the same
/// category over and over, and being wrong costs one tap to change.
@MainActor
public enum PayeeMemory {
    /// The category used most recently for this payee.
    ///
    /// Recency beats frequency: if a payee has moved to a different category, the newest choice is the
    /// one to repeat, not the one made most often years ago.
    public static func lastCategory(
        forPayeeNamed name: String,
        in context: ModelContext
    ) throws -> BudgetCategoryModel? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var descriptor = FetchDescriptor<LedgerTransaction>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        // Fetching a window rather than the whole register: the answer is nearly always in the most
        // recent entries, and a predicate cannot reach through the payee relationship reliably.
        descriptor.fetchLimit = 400

        let recent = try context.fetch(descriptor)
        return recent.first {
            $0.payee?.name.caseInsensitiveCompare(trimmed) == .orderedSame && $0.category != nil
        }?.category
    }

    /// Payees whose names match what has been typed, most recently used first.
    ///
    /// A name typed out in full is still offered, first: choosing it is what fills in the payee's
    /// last category, so dropping it once it matched exactly took that away from anyone who typed
    /// the whole name. Typing "Other" offered only "Brother".
    public static func suggestions(
        matching text: String,
        in context: ModelContext,
        limit: Int = 5
    ) throws -> [Payee] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return suggestions(matching: needle, among: try context.fetch(FetchDescriptor<Payee>()), limit: limit)
    }

    /// The same, from payees already in hand. The editor asks on every keystroke, and fetching
    /// every payee each time is what it was waiting on.
    public static func suggestions(
        matching text: String,
        among payees: [Payee],
        limit: Int = 5
    ) -> [Payee] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let payees = SyncMerge.survivingPayees(payees)

        let exact = payees.filter { $0.name.lowercased() == needle }
        let prefixed = payees.filter {
            $0.name.lowercased().hasPrefix(needle) && $0.name.lowercased() != needle
        }
        let contained = payees.filter {
            !$0.name.lowercased().hasPrefix(needle) && $0.name.lowercased().contains(needle)
        }

        func byRecency(_ lhs: Payee, _ rhs: Payee) -> Bool {
            (lhs.lastUsedAt ?? .distantPast) > (rhs.lastUsedAt ?? .distantPast)
        }
        return Array(
            (exact + prefixed.sorted(by: byRecency) + contained.sorted(by: byRecency))
                .prefix(limit)
        )
    }
}

/// Marking a transaction cleared or not, from a swipe in any list.
@MainActor
public enum ClearedStatusWriter {
    /// Flips between cleared and uncleared.
    ///
    /// A reconciled entry is left alone: reconciling means it was checked against a statement, and
    /// undoing that by accident in a list would quietly break the reconciliation.
    public static func toggleCleared(_ transaction: LedgerTransaction, in context: ModelContext) throws {
        switch transaction.cleared {
        case .uncleared:
            transaction.cleared = .cleared
        case .cleared:
            transaction.cleared = .uncleared
        case .reconciled:
            return
        }
        try context.save()
    }

    public static func canToggle(_ transaction: LedgerTransaction) -> Bool {
        transaction.cleared != .reconciled
    }
}
