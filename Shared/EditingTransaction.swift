import EmbersData
import Foundation

/// A transaction to open in the editor, for a `.sheet(item:)`.
///
/// Not the transaction itself: its `Identifiable` id is asked for again while the sheet is
/// dismissing, which after a delete is a read of a destroyed row, and that is fatal.
struct EditingTransaction: Identifiable {
    let transaction: LedgerTransaction
    var id: ObjectIdentifier { ObjectIdentifier(transaction) }
}
