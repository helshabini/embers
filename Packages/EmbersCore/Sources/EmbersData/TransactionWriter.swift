import Foundation
import EmbersCore
import SwiftData

/// Removing transactions.
///
/// Deleting one side of a transfer would leave money arriving from nowhere in the other account, so
/// both sides always go together. Split lines follow their parent through the cascade rule.
@MainActor
public enum TransactionWriter {
    /// Deletes a transaction, taking the other side of a transfer with it.
    ///
    /// - Returns: How many rows were removed, which the caller can report.
    @discardableResult
    public static func delete(
        _ transaction: LedgerTransaction,
        in context: ModelContext
    ) throws -> Int {
        let sides = try TransferWriter.pair(of: transaction, in: context)
        for side in sides {
            context.delete(side)
        }
        try context.save()
        return sides.count
    }

    /// What deleting this would take with it, so the confirmation can say so.
    public static func deletionSummary(
        _ transaction: LedgerTransaction,
        in context: ModelContext
    ) -> String {
        if transaction.isTransfer {
            let other = (try? TransferWriter.counterpartAccount(of: transaction, in: context))?.name
            return other.map {
                String(
                    localized: "This removes both sides of the transfer, here and in \($0).",
                    bundle: .module
                )
            } ?? String(localized: "This removes both sides of the transfer.", bundle: .module)
        }
        let lines = transaction.splitLines?.count ?? 0
        if lines > 0 {
            return String(
                localized: "This removes the transaction and its \(lines) split lines.", bundle: .module,
                locale: .display
            )
        }
        return String(localized: "This cannot be undone.", bundle: .module)
    }
}
