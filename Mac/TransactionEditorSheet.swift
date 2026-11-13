import EmbersData
import SwiftUI

/// The inspector's editor in a sheet, for screens with no table beside them to edit in.
struct TransactionEditorSheet: View {
    /// Nil for a new entry.
    var transaction: LedgerTransaction?
    /// Where a new entry starts.
    var category: BudgetCategoryModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TransactionEditor(
            account: nil,
            existing: transaction,
            category: category,
            onFinish: { _ in dismiss() },
            onCancel: { dismiss() }
        )
        .frame(width: 420, height: 620)
    }
}
