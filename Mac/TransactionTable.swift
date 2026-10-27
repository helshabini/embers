import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// One transaction as the table shows it, read once when the rows are loaded.
///
/// The cells read only this, never the model. A table renders at least once more after a delete,
/// and reading any attribute of a deleted transaction is fatal rather than a nil — the phone learned
/// that from a crash log (see `LedgerTransaction.isLive`).
struct LedgerRow: Identifiable {
    let id: PersistentIdentifier
    /// For acting on, never for drawing. Check `isLive` first.
    let transaction: LedgerTransaction

    let date: Date
    let createdAt: Date
    let dateText: String
    let account: String
    let payee: String
    let category: String
    let memo: String
    /// Signed, in the plan's currency; shown as a plain magnitude when `isPlainMove`.
    let amount: MinorUnits
    let isPlainMove: Bool
    let entered: String
    let repeats: String
    let cleared: ClearedStatus
    let canToggleCleared: Bool
    /// Has not happened: dated later than today, or waiting to be approved.
    let isScheduled: Bool
    let isDue: Bool
    let isUncategorized: Bool

    @MainActor
    init(_ transaction: LedgerTransaction, collapsesTransfer: Bool, budget: BudgetModel, uncategorized: Set<UUID>) {
        let wording = TransactionWording(transaction: transaction, collapsesTransfer: collapsesTransfer)
        id = transaction.persistentModelID
        self.transaction = transaction
        date = transaction.date
        createdAt = transaction.createdAt
        dateText = wording.shortDate
        account = transaction.account?.name ?? ""
        payee = wording.title
        category = wording.categoryText ?? ""
        memo = transaction.memo
        amount = MinorUnits(transaction.amountMinor)
        isPlainMove = wording.isPlainMove
        entered = wording.conversionSummary ?? ""
        repeats = transaction.recurrence?.shortName ?? ""
        cleared = transaction.cleared
        canToggleCleared = ClearedStatusWriter.canToggle(transaction)
        isScheduled = !budget.hasHappened(transaction)
        isDue = transaction.isDue(asOf: budget.activityCutoff)
        isUncategorized = uncategorized.contains(transaction.identifier)
    }

    /// For sorting by amount: a plain move sorts by its size, as it is shown.
    var shownAmount: MinorUnits { isPlainMove ? abs(amount) : amount }
}

/// The register as a desktop table: one line per transaction, sortable, several selectable at once.
///
/// What the phone does with swipes is here on the context menu and the keyboard: Delete removes,
/// and the cleared mark toggles with a click.
struct TransactionTable: View {
    let rows: [LedgerRow]
    let showsAccount: Bool
    @Binding var selection: Set<PersistentIdentifier>
    @Binding var sortOrder: [KeyPathComparator<LedgerRow>]
    /// Opens a row for editing: a double-click, or Return.
    var onOpen: (LedgerRow) -> Void = { _ in }
    /// Something here changed the store; the rows need reading again.
    var onChange: () -> Void

    @Environment(BudgetModel.self) private var budget
    @Environment(\.modelContext) private var modelContext
    @SceneStorage("transactionTable.columns") private var columns = TableColumnCustomization<LedgerRow>()
    @State private var deleting: Deletion?

    private struct Deletion {
        let transactions: [LedgerTransaction]
        /// Worked out before asking. The alert renders again as it closes, after the delete, and
        /// reading a deleted row then is fatal.
        let message: String
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            // No title: the marks say what the column is, and a word would only widen it.
            TableColumn(Text(verbatim: "")) { row in
                ClearedMark(row: row) { toggleCleared([row]) }
            }
            .width(22)
            .customizationID("cleared")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Date", value: \.date) { row in
                Text(row.dateText)
                    .foregroundStyle(row.isScheduled ? Color.orange : .primary)
            }
            .width(min: 70, ideal: 90, max: 130)
            .customizationID("date")

            if showsAccount {
                TableColumn("Account", value: \.account) { row in
                    Text(row.account).lineLimit(1).dimmed(row)
                }
                .width(min: 90, ideal: 140)
                .customizationID("account")
            }

            TableColumn("Payee", value: \.payee) { row in
                HStack(spacing: 4) {
                    if row.isDue {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(Color.orange)
                            .help("Awaiting approval")
                    }
                    Text(row.payee).lineLimit(1)
                }
                .dimmed(row)
            }
            .width(min: 120, ideal: 200)
            .customizationID("payee")

            TableColumn("Category", value: \.category) { row in
                if row.isUncategorized {
                    // Money that moved without a category is invisible to the plan.
                    Label("Uncategorized", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                        .lineLimit(1)
                } else {
                    Text(row.category).lineLimit(1).dimmed(row)
                }
            }
            .width(min: 100, ideal: 170)
            .customizationID("category")

            // Beside the category rather than at the far end: with the editor open the table is
            // narrower, and the amount is the one column that must never be cut off.
            TableColumn("Amount", value: \.shownAmount) { row in
                Text(budget.money(row.shownAmount))
                    .monospacedDigit()
                    .fontWeight(.medium)
                    .foregroundStyle(row.isPlainMove ? .secondary : Flame.amountColor(row.amount))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .dimmed(row)
            }
            .width(min: 90, ideal: 120)
            .customizationID("amount")

            TableColumn("Memo", value: \.memo) { row in
                Text(row.memo)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(row.memo)
                    .dimmed(row)
            }
            .width(min: 60, ideal: 150)
            .customizationID("memo")

            // What was actually typed, for a converted entry: the signature of this app, and how a
            // converted payment is recognised months later.
            TableColumn("Entered", value: \.entered) { row in
                Text(row.entered)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .dimmed(row)
            }
            .width(min: 60, ideal: 120)
            .customizationID("entered")

            TableColumn("Repeats", value: \.repeats) { row in
                if !row.repeats.isEmpty {
                    Label(row.repeats, systemImage: "arrow.trianglehead.2.clockwise")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .dimmed(row)
                }
            }
            .width(min: 60, ideal: 100)
            .customizationID("repeats")

        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            menu(for: chosen(ids))
        } primaryAction: { ids in
            if let first = chosen(ids).first { onOpen(first) }
        }
        .onDeleteCommand { askToDelete(chosen(selection)) }
        .alert(
            deleting.map { $0.transactions.count == 1 ? "Delete this transaction?" : "Delete \($0.transactions.count) transactions?" } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { deletion in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { delete(deletion.transactions) }
        } message: { deletion in
            Text(deletion.message)
        }
    }

    private func chosen(_ ids: Set<PersistentIdentifier>) -> [LedgerRow] {
        rows.filter { ids.contains($0.id) && $0.transaction.isLive }
    }

    @ViewBuilder
    private func menu(for chosen: [LedgerRow]) -> some View {
        if chosen.count == 1, let row = chosen.first {
            Button("Edit…") { onOpen(row) }
        }
        let toggleable = chosen.filter(\.canToggleCleared)
        if !toggleable.isEmpty {
            if toggleable.contains(where: { $0.cleared == .uncleared }) {
                Button("Mark as Cleared") { setCleared(toggleable, to: true) }
            }
            if toggleable.contains(where: { $0.cleared == .cleared }) {
                Button("Mark as Uncleared") { setCleared(toggleable, to: false) }
            }
        }
        let due = chosen.filter(\.isDue)
        if !due.isEmpty {
            Divider()
            Button(due.count == 1 ? "Approve" : "Approve \(due.count)") { approve(due) }
            Button(due.count == 1 ? "Skip This One" : "Skip \(due.count)") { skip(due) }
        }
        if !chosen.isEmpty {
            Divider()
            Button(chosen.count == 1 ? "Delete…" : "Delete \(chosen.count)…", role: .destructive) {
                askToDelete(chosen)
            }
        }
    }

    // MARK: - Acting

    /// No recompute: a cleared flag changes no activity, available or Ready to Assign, and the phone
    /// learned that refreshing here re-read the whole register on every swipe.
    private func toggleCleared(_ rows: [LedgerRow]) {
        for row in rows where row.transaction.isLive && row.canToggleCleared {
            try? ClearedStatusWriter.toggleCleared(row.transaction, in: modelContext)
        }
        onChange()
    }

    private func setCleared(_ rows: [LedgerRow], to cleared: Bool) {
        toggleCleared(rows.filter { ($0.cleared == .uncleared) == cleared })
    }

    private func approve(_ rows: [LedgerRow]) {
        for row in rows where row.transaction.isLive {
            try? RecurrenceWriter.approve(row.transaction, in: modelContext)
        }
        budget.refresh(in: modelContext)
    }

    private func skip(_ rows: [LedgerRow]) {
        for row in rows where row.transaction.isLive {
            try? RecurrenceWriter.skip(row.transaction, in: modelContext)
        }
        selection = []
        budget.refresh(in: modelContext)
    }

    private func askToDelete(_ rows: [LedgerRow]) {
        guard !rows.isEmpty else { return }
        let transactions = rows.map(\.transaction)
        let message = transactions.count == 1
            ? TransactionWriter.deletionSummary(transactions[0], in: modelContext)
            : String(localized: "Transfers lose both sides, and splits all their lines.")
        deleting = Deletion(transactions: transactions, message: message)
    }

    private func delete(_ transactions: [LedgerTransaction]) {
        selection = []
        // One side of a transfer takes the other with it, which may be the next one in the list.
        for transaction in transactions where transaction.isLive {
            try? TransactionWriter.delete(transaction, in: modelContext)
        }
        budget.refresh(in: modelContext)
    }
}

/// The cleared state, and the click that changes it.
///
/// A reconciled entry offers nothing: reconciling means it was checked against a statement, and
/// undoing that from a list would quietly break the reconciliation.
private struct ClearedMark: View {
    let row: LedgerRow
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .disabled(!row.canToggleCleared)
        .help(help)
        .accessibilityIdentifier("cleared-mark")
    }

    private var symbol: String {
        switch row.cleared {
        case .uncleared: "circle.dotted"
        case .cleared: "checkmark.circle.fill"
        case .reconciled: "lock.fill"
        }
    }

    /// Reconciled is settled history, so it steps back rather than sharing cleared's green.
    private var color: Color {
        switch row.cleared {
        case .uncleared, .reconciled: .secondary
        case .cleared: Flame.inflow
        }
    }

    private var help: String {
        switch row.cleared {
        case .uncleared: String(localized: "Uncleared. Click to mark as cleared.")
        case .cleared: String(localized: "Cleared. Click to mark as uncleared.")
        case .reconciled: String(localized: "Reconciled against a statement.")
        }
    }
}

private extension View {
    /// Scheduled entries have not happened, so they sit back from the ones that have, as on the phone.
    func dimmed(_ row: LedgerRow) -> some View {
        opacity(row.isScheduled ? 0.55 : 1)
    }
}
