import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

struct RegisterView: View {
    let account: Account

    @State private var searchText = ""
    /// What the list is filtered by: the field's text, once typing pauses.
    @State private var search = ""

    // The field lives here and the list below, so a keystroke redraws only this. Held together,
    // every letter re-ran the list's body — the balances summed over each of the account's rows,
    // three thousand on the busiest, and the filter over them — before the letter appeared.
    var body: some View {
        RegisterList(account: account, search: search)
            .searchable(text: $searchText, prompt: "Payee, memo or amount")
            .task(id: searchText) {
                if !searchText.isEmpty {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                }
                search = searchText
            }
    }
}

private struct RegisterList: View {
    let account: Account
    let search: String

    @Environment(BudgetModel.self) private var budget
    @Environment(\.modelContext) private var modelContext
    @Query private var transactions: [LedgerTransaction]
    /// One sheet, not three. SwiftUI honours a single `.sheet` per view, so stacking them left
    /// whichever lost the race silently doing nothing — which is how tapping a row to edit it stopped
    /// opening the editor.
    @State private var sheet: Sheet?
    /// Closed by default and remembered across accounts: a register that opens on a run of scheduled
    /// entries hides everything that has actually happened.
    @AppStorage("scheduledExpanded") private var isScheduledExpanded = false

    private enum Sheet: Identifiable {
        case adding
        case reconciling
        case editing(LedgerTransaction)

        var id: String {
            switch self {
            case .adding: "adding"
            case .reconciling: "reconciling"
            // Not the transaction's identifier: SwiftUI asks for this again while the sheet is
            // dismissing, which after a delete is a read of a destroyed row, and that is fatal.
            case let .editing(transaction): "\(ObjectIdentifier(transaction))"
            }
        }
    }

    init(account: Account, search: String) {
        self.account = account
        self.search = search
        let accountID = account.identifier
        // Split lines belong to their parent's row, so the register lists parents only.
        _transactions = Query(
            filter: #Predicate<LedgerTransaction> { transaction in
                transaction.account?.identifier == accountID && transaction.parent == nil
            },
            sort: LedgerTransaction.newestFirst
        )
    }

    var body: some View {
        List {
            let totals = settledTotals
            Section {
                LabeledContent("Working balance") {
                    Text(budget.money(budget.balance(of: account)))
                        .font(.headline)
                        .foregroundStyle(Flame.amountColor(budget.balance(of: account)))
                }
                // Keys of their own: these label sums of money, which many languages word apart
                // from a transaction's own cleared state — and inflect differently.
                LabeledContent(
                    String(localized: "balance.cleared", defaultValue: "Cleared"),
                    value: budget.money(totals.cleared)
                )
                LabeledContent(
                    String(localized: "balance.uncleared", defaultValue: "Uncleared"),
                    value: budget.money(totals.uncleared)
                )
                if budget.upcoming(of: account) != 0 {
                    LabeledContent("Upcoming", value: budget.money(budget.upcoming(of: account)))
                        .foregroundStyle(.secondary)
                }
            }

            let split = visibleTransactions.splitBySchedule(after: budget.activityCutoff)

            if !split.scheduled.isEmpty {
                Section {
                    if isScheduledExpanded {
                        // Named apart from the settled rows so a test can say whether the section is
                        // open, rather than counting rows and being told what a lazy list happened
                        // to render.
                        ForEach(split.scheduled) { row($0).accessibilityIdentifier("scheduled-row") }
                    }
                } header: {
                    ScheduledHeader(
                        count: split.scheduled.count,
                        totalMinor: split.scheduled.reduce(0) { $0 + MinorUnits($1.amountMinor) },
                        isExpanded: $isScheduledExpanded
                    )
                }
            }

            Section {
                ForEach(split.settled) { row($0) }
            } header: {
                Text("\(split.settled.count) transactions")
            }
        }
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    sheet = .adding
                } label: {
                    Label("Add Transaction", systemImage: "plus")
                }
                .accessibilityIdentifier("add-transaction")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    sheet = .reconciling
                } label: {
                    Label("Reconcile", systemImage: "checkmark.seal")
                }
                .accessibilityIdentifier("reconcile")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    AccountSettingsView(account: account)
                } label: {
                    Label("Account Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("account-settings")
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .adding:
                TransactionEditorView(account: account, existing: nil)
            case .reconciling:
                ReconcileView(account: account)
            case let .editing(transaction):
                TransactionEditorView(account: account, existing: transaction)
            }
        }
    }


    /// One row, wherever it sits.
    @ViewBuilder
    private func row(_ transaction: LedgerTransaction) -> some View {
        Button {
            sheet = .editing(transaction)
        } label: {
            TransactionRow(transaction: transaction)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transaction-row")
        // Without this the separator starts at whichever subview SwiftUI picks, which on a repeating
        // row was halfway across.
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            ClearedSwipeButton(transaction: transaction)
        }
        .swipeActions(edge: .trailing) {
            DeleteSwipeButton(transaction: transaction)
        }
    }

    private var visibleTransactions: [LedgerTransaction] {
        let live = transactions.filter(\.isLive)
        guard !search.isEmpty else { return live }
        let needle = search.lowercased()
        return live.filter { transaction in
            if transaction.payee?.displayName.lowercased().contains(needle) == true { return true }
            if transaction.memo.lowercased().contains(needle) { return true }
            if transaction.category?.displayName.lowercased().contains(needle) == true { return true }
            return String(abs(transaction.amountMinor)).contains(needle.filter(\.isNumber))
                && needle.contains(where: \.isNumber)
        }
    }

    /// Cleared and uncleared must add up to the working balance, so upcoming entries are left out of
    /// both and reported on their own line. Summed in one pass: both are shown, and as two they
    /// read every row twice.
    private var settledTotals: (cleared: MinorUnits, uncleared: MinorUnits) {
        var cleared: Int64 = 0
        var uncleared: Int64 = 0
        for transaction in transactions where transaction.isLive && budget.hasHappened(transaction) {
            if transaction.cleared == .uncleared {
                uncleared += Int64(transaction.amountMinor)
            } else {
                cleared += Int64(transaction.amountMinor)
            }
        }
        return (MinorUnits(cleared), MinorUnits(uncleared))
    }
}

struct TransactionRow: View {
    let transaction: LedgerTransaction
    var showsAccount = false
    /// Stands for both sides of a transfer, in a list that holds them both. A register only ever
    /// holds one side, so there it stays false.
    var collapsesTransfer = false
    @Environment(BudgetModel.self) private var budget

    /// Two columns of at most three lines each.
    ///
    /// The repeat rule and the entered foreign amount used to take a full line apiece on the left,
    /// which made a repeating transfer four lines tall — and a register opening on a run of them
    /// showed almost nothing else. The rule sits opposite the conversion now, the way YNAB puts
    /// "Repeats every 3 months" across from the category.
    var body: some View {
        // The row watches its own transaction, so a delete invalidates it directly — and it can be
        // drawn again before the list that filters out deleted rows is. Reading a deleted row is
        // fatal: the crash log on the phone stopped in `conversion`, after a transfer to a card
        // was deleted.
        if transaction.isLive { content }
    }

    private var content: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let conversion = wording.conversionSummary {
                    Text(conversion)
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(amountText)
                    .monospacedDigit()
                    .fontWeight(.medium)
                    .foregroundStyle(amountColor)
                HStack(spacing: 4) {
                    Text(wording.shortDate)
                    clearedMark
                }
                .font(.caption2)
                .foregroundStyle(isScheduled ? Color.orange : Color.secondary)
                if transaction.isDue(asOf: budget.activityCutoff) {
                    Label("Awaiting approval", systemImage: "clock.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(Color.orange)
                        .lineLimit(1)
                }
                if let rule = transaction.recurrence {
                    Label(rule.shortName, systemImage: "arrow.trianglehead.2.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // The right column states facts that cannot be abbreviated — an amount, a date, how
            // often — so it takes the width it needs and the payee truncates instead.
            .layoutPriority(1)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Without this the gaps between the labels are not part of the button, so tapping a row
        // works in some places and does nothing in others.
        .contentShape(Rectangle())
        // Scheduled entries have not happened, so they sit back from the ones that have.
        .opacity(isScheduled ? 0.55 : 1)
    }

    /// Dated later than today, or waiting to be approved: money that has not moved yet.
    private var isScheduled: Bool { !budget.hasHappened(transaction) }

    private var wording: TransactionWording {
        TransactionWording(transaction: transaction, collapsesTransfer: collapsesTransfer)
    }

    private var amountText: String {
        let amount = MinorUnits(transaction.amountMinor)
        return budget.money(wording.isPlainMove ? abs(amount) : amount)
    }

    private var amountColor: Color {
        wording.isPlainMove ? .secondary : Flame.amountColor(MinorUnits(transaction.amountMinor))
    }

    private var title: String { wording.title }

    private var subtitle: String {
        var parts: [String] = []
        if showsAccount, let name = transaction.account?.name { parts.append(name) }
        if let category = wording.categoryText { parts.append(category) }
        if !transaction.memo.isEmpty { parts.append(transaction.memo) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var clearedMark: some View {
        switch transaction.cleared {
        case .uncleared:
            Image(systemName: "circle.dotted")
        case .cleared:
            Image(systemName: "checkmark.circle")
        case .reconciled:
            Image(systemName: "lock.circle")
        }
    }
}

/// Marks a transaction cleared, or takes it back, from a swipe.
///
/// A reconciled entry offers nothing: reconciling means it was checked against a statement, and
/// undoing that from a list would quietly break the reconciliation.
struct ClearedSwipeButton: View {
    let transaction: LedgerTransaction

    @Environment(\.modelContext) private var modelContext
    @Environment(BudgetModel.self) private var budget

    var body: some View {
        if transaction.isLive, ClearedStatusWriter.canToggle(transaction) {
            Button {
                // No recompute: a cleared flag changes no activity, available or Ready to Assign,
                // and refreshing here re-read the entire register on every swipe.
                try? ClearedStatusWriter.toggleCleared(transaction, in: modelContext)
            } label: {
                Label(
                    transaction.cleared == .cleared ? String(localized: "Unclear") : String(localized: "Clear"),
                    systemImage: transaction.cleared == .cleared ? "circle.dotted" : "checkmark.circle"
                )
            }
            .tint(transaction.cleared == .cleared ? .gray : Flame.inflow)
        }
    }
}

/// Deletes a transaction, and the other side of a transfer with it.
struct DeleteSwipeButton: View {
    let transaction: LedgerTransaction

    @Environment(\.modelContext) private var modelContext
    @Environment(BudgetModel.self) private var budget
    @State private var isConfirming = false
    /// Worked out on the tap, not in the alert. The alert's message is rendered again as it closes,
    /// which is after the delete — and reading a deleted transaction is a crash, not a nil.
    @State private var summary = ""

    var body: some View {
        Button(role: .destructive) {
            summary = TransactionWriter.deletionSummary(transaction, in: modelContext)
            isConfirming = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .tint(Flame.outflow)
        .alert("Delete this transaction?", isPresented: $isConfirming) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                try? TransactionWriter.delete(transaction, in: modelContext)
                budget.refresh(in: modelContext)
            }
        } message: {
            Text(summary)
        }
    }
}
