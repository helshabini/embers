import Foundation
import EmbersCore
import SwiftData

/// Shaping a list of entries for reading.
///
/// Kept out of the views so it can be checked without a screen: the rules about which row stands for
/// a transfer, and where the line between what has happened and what has not falls, are the kind of
/// thing that is quietly wrong until someone counts.
extension Array where Element == LedgerTransaction {
    /// Drops the second row of every transfer, so a list spanning all accounts shows each transfer
    /// once rather than twice.
    ///
    /// The side that is kept is the one money left, which is also the side that carries a category
    /// when the transfer leaves the budget. A transfer whose counterpart is not in this list — a
    /// filtered search, or a half that was never paired — is kept as it is rather than hidden.
    public func collapsingTransferPairs() -> [LedgerTransaction] {
        var seen: Set<UUID> = []
        var kept: [LedgerTransaction] = []
        // Which pairs are here in full: only those can safely lose a side. Held by pair rather than
        // counted, so an incoming side finds its partner here instead of by scanning the whole list —
        // a search matching most of a ten-thousand-row register made that scan quadratic.
        var sides: [UUID: [LedgerTransaction]] = [:]
        for transaction in self {
            if let pair = transaction.transferPairIdentifier { sides[pair, default: []].append(transaction) }
        }

        for transaction in self {
            guard let pair = transaction.transferPairIdentifier, let both = sides[pair], both.count == 2 else {
                kept.append(transaction)
                continue
            }
            guard !seen.contains(pair) else { continue }
            seen.insert(pair)
            // Prefer the outgoing side; if this is the incoming one, its partner stands in.
            if transaction.amountMinor <= 0 {
                kept.append(transaction)
            } else {
                kept.append(both.first { $0 !== transaction } ?? transaction)
            }
        }
        return kept
    }

    /// Splits a register into what has not happened yet and what has.
    ///
    /// `cutoff` is the end of today, so an entry dated today counts as settled: it is money that has
    /// moved, not money that is going to. One still awaiting approval has not moved, whatever its date.
    public func splitBySchedule(after cutoff: Date) -> (scheduled: [LedgerTransaction], settled: [LedgerTransaction]) {
        var scheduled: [LedgerTransaction] = []
        var settled: [LedgerTransaction] = []
        for transaction in self {
            if transaction.hasHappened(asOf: cutoff) { settled.append(transaction) } else { scheduled.append(transaction) }
        }
        return (scheduled, settled)
    }
}

extension LedgerTransaction {
    /// False once the row has been deleted.
    ///
    /// A list holding its rows in state, or a sheet closing over one, renders at least once more
    /// after a delete, and reading any attribute of a deleted row is a fatal error rather than a nil
    /// — which is how deleting a transaction crashed the app some of the time and not others.
    public var isLive: Bool { !isDeleted && modelContext != nil }

    /// Dated on or before `cutoff` and not waiting for anyone: money that has actually moved.
    public func hasHappened(asOf cutoff: Date) -> Bool { !awaitsApproval && date <= cutoff }

    /// Its day has come and it is waiting to be approved or skipped.
    public func isDue(asOf cutoff: Date) -> Bool { awaitsApproval && date <= cutoff }

    /// Latest day first and, within a day, the latest entered first.
    ///
    /// By date alone, entries sharing a day came back in whatever order the store kept them, so the
    /// one just typed could land anywhere among that day's — usually not at the top, where the eye
    /// goes to check it.
    public static var newestFirst: [SortDescriptor<LedgerTransaction>] {
        [
            SortDescriptor(\.date, order: .reverse),
            SortDescriptor(\.createdAt, order: .reverse),
        ]
    }
}
