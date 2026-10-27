import EmbersData
import SwiftUI

/// The inspector's editor in a sheet, for screens with no table beside them to edit in.
struct TransactionEditorSheet: View {
    let transaction: LedgerTransaction
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TransactionEditor(
            account: nil,
            existing: transaction,
            onFinish: { _ in dismiss() },
            onCancel: { dismiss() }
        )
        .frame(width: 420, height: 620)
    }
}
