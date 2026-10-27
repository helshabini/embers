import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// An account's register, or every account's transactions: the same table, read differently.
struct TransactionsScreen: View {
    enum Scope: Equatable {
        case all
        case account(Account)
    }

    /// What All Transactions is narrowed to. The phone opens a screen for each of the two that wait
    /// on a decision; here they are filters on the one table, so a row is acted on where it is seen.
    enum Filter: Hashable {
        case everything
        case toApprove
        case uncategorized
    }

    let scope: Scope
    /// Set when the menu asks for a new entry, and cleared here once one is open.
    @Binding var newEntryRequest: UUID?

    @Environment(BudgetModel.self) private var budget
    @Environment(\.modelContext) private var modelContext

    @State private var rows: [LedgerRow] = []
    @State private var scheduledCount = 0
    @State private var scheduledTotal: MinorUnits = 0
    @State private var settledTotals: (cleared: MinorUnits, uncleared: MinorUnits) = (0, 0)
    @State private var isTruncated = false
    @State private var selection: Set<PersistentIdentifier> = []
    @State private var sortOrder = [KeyPathComparator(\LedgerRow.date, order: .reverse)]
    @State private var filter = Filter.everything
    @State private var searchText = ""
    /// What the inspector is editing. A fresh token is a fresh blank entry.
    @State private var editing: Editing?
    @AppStorage("register.showsInspector") private var showsInspector = true
    /// The account last written to, so a new entry from All Transactions opens where the last one went.
    @AppStorage("lastAccountIdentifier") private var lastAccountIdentifier = ""
    @Query(sort: \Account.order) private var accounts: [Account]

    /// One sheet, as everywhere in this app: SwiftUI honours a single `.sheet` per view.
    @State private var sheet: Sheet?

    private enum Sheet: Identifiable {
        case reconciling(Account)
        case accountSettings(Account)

        var id: String {
            switch self {
            case .reconciling: "reconciling"
            case .accountSettings: "accountSettings"
            }
        }
    }

    private enum Editing: Hashable {
        case new(UUID)
        case existing(PersistentIdentifier)
    }
    /// Shared with the phone's register: folding the scheduled entries away is one decision.
    @AppStorage("scheduledExpanded") private var isScheduledExpanded = false

    /// How many of the newest entries All Transactions shows before asking for a search. More than the
    /// phone's three hundred — a table draws only what is on screen — but reading all ten thousand
    /// on every edit would be felt.
    private static let pageSize = 1000

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TransactionTable(
                rows: rows,
                showsAccount: scope == .all,
                selection: $selection,
                sortOrder: $sortOrder,
                onOpen: { row in
                    selection = [row.id]
                    showsInspector = true
                },
                onChange: load
            )
            if isTruncated {
                Text("Showing the most recent \(Self.pageSize). Search to find older transactions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .inspector(isPresented: $showsInspector) {
            editor
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .toolbar {
            if case let .account(account) = scope {
                ToolbarItem {
                    Button {
                        sheet = .reconciling(account)
                    } label: {
                        Label("Reconcile", systemImage: "checkmark.seal")
                    }
                    .help("Check this account against a statement")
                    .accessibilityIdentifier("reconcile")
                }
                ToolbarItem {
                    Button {
                        sheet = .accountSettings(account)
                    } label: {
                        Label("Account Settings", systemImage: "info.circle")
                    }
                    .keyboardShortcut("i", modifiers: .command)
                    .help("Account settings (⌘I)")
                    .accessibilityIdentifier("account-settings")
                }
            }
            ToolbarItem {
                Button {
                    startNewEntry()
                } label: {
                    Label("New Transaction", systemImage: "plus")
                }
                .help("New transaction (⌘N)")
                .accessibilityIdentifier("add-transaction")
            }
            ToolbarItem {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Transaction Details", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the transaction editor")
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case let .reconciling(account):
                ReconcileView(account: account)
                    .frame(minWidth: 460, minHeight: 440)
            case let .accountSettings(account):
                NavigationStack {
                    AccountSettingsView(account: account)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { sheet = nil }
                            }
                        }
                }
                .formStyle(.grouped)
                .frame(minWidth: 460, minHeight: 480)
            }
        }
        // A single row selected is a row to edit. Several selected is something to act on together,
        // from the context menu, not to edit one of.
        .onChange(of: selection) { _, chosen in
            if chosen.count == 1, let id = chosen.first {
                editing = .existing(id)
            } else if case .existing = editing {
                editing = nil
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Payee, memo, category or amount")
        .task(id: searchText) {
            // A pause before searching, so a word typed quickly is one search, not one per letter.
            if !searchText.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            load()
        }
        .onChange(of: budget.revision) { _, _ in load() }
        .onChange(of: scope) { _, _ in
            selection = []
            editing = nil
            filter = .everything
            load()
        }
        .onChange(of: filter) { _, _ in
            selection = []
            load()
        }
        .onChange(of: isScheduledExpanded) { _, _ in load() }
        // From the menu. Taken from the change, not the closure's capture.
        .onChange(of: newEntryRequest) { _, request in
            if request != nil { answerNewEntryRequest() }
        }
        // Asked for from another screen, which brought this one up to answer it.
        .onAppear { if newEntryRequest != nil { answerNewEntryRequest() } }
        .onChange(of: sortOrder) { _, _ in load() }
    }

    // MARK: - The editor

    @ViewBuilder
    private var editor: some View {
        switch editing {
        case let .new(token):
            TransactionEditor(account: newEntryAccount, existing: nil, onFinish: { _ in
                // Straight into the next one: receipts come in piles.
                editing = .new(UUID())
            }, onCancel: { editing = nil })
            .id(token)
        case let .existing(id):
            if let transaction = rows.first(where: { $0.id == id })?.transaction, transaction.isLive {
                TransactionEditor(account: nil, existing: transaction, onFinish: { _ in
                    selection = []
                    editing = nil
                }, onCancel: {
                    selection = []
                    editing = nil
                })
                .id(id)
            } else {
                noEditor
            }
        case nil:
            noEditor
        }
    }

    private var noEditor: some View {
        ContentUnavailableView {
            Label("No transaction selected", systemImage: "arrow.left.arrow.right")
        } description: {
            Text("Select one to edit it, or start a new one.")
        } actions: {
            Button("New Transaction", action: startNewEntry)
        }
    }

    private func answerNewEntryRequest() {
        newEntryRequest = nil
        startNewEntry()
    }

    private func startNewEntry() {
        selection = []
        editing = .new(UUID())
        showsInspector = true
    }

    /// The register's own account; across all accounts, the one written to last.
    private var newEntryAccount: Account? {
        if case let .account(account) = scope { return account }
        return accounts.first { $0.identifier.uuidString == lastAccountIdentifier && !$0.closed }
            ?? accounts.first { !$0.closed }
    }

    // MARK: - Above the table

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            switch scope {
            case let .account(account):
                Figure(title: String(localized: "Working balance"), amount: budget.balance(of: account), emphasised: true)
                // Keys of their own: these label sums of money, which many languages word apart
                // from a transaction's own cleared state — and inflect differently.
                Figure(title: String(localized: "balance.cleared", defaultValue: "Cleared"), amount: settledTotals.cleared)
                Figure(title: String(localized: "balance.uncleared", defaultValue: "Uncleared"), amount: settledTotals.uncleared)
                if budget.upcoming(of: account) != 0 {
                    Figure(title: String(localized: "Upcoming"), amount: budget.upcoming(of: account))
                        .opacity(0.7)
                }
            case .all:
                attentionFilter
            }
            Spacer()
            if filter == .everything, scheduledCount > 0 {
                scheduledToggle
            }
            if filter == .toApprove, budget.dueForApprovalCount > 0 {
                Button("Approve All") {
                    try? RecurrenceWriter.approveDue(in: modelContext, asOf: budget.activityCutoff)
                    budget.refresh(in: modelContext)
                }
                .accessibilityIdentifier("approve-all")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Up top, where they are seen: each waits on a decision, and until it is made the plan is not
    /// telling the whole story.
    @ViewBuilder
    private var attentionFilter: some View {
        if budget.dueForApprovalCount > 0 || !budget.uncategorized.isEmpty || filter != .everything {
            Picker("Show", selection: $filter) {
                Text("All").tag(Filter.everything)
                Text("\(budget.dueForApprovalCount) to approve", comment: "A filter: scheduled entries waiting for approval")
                    .tag(Filter.toApprove)
                Text(String(localized: "\(budget.uncategorized.count) uncategorized transactions", locale: .display))
                    .tag(Filter.uncategorized)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("attention-filter")
        } else {
            Label("Nothing waiting on you", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var scheduledToggle: some View {
        Toggle(isOn: $isScheduledExpanded) {
            HStack(spacing: 6) {
                Text("Scheduled")
                Text("\(scheduledCount)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Flame.tintedFill, in: Capsule())
                    .foregroundStyle(Flame.deep)
                // Across all accounts both sides of every scheduled transfer are listed, so they
                // cancel and a total reads as a few pounds of nothing.
                if case .account = scope {
                    Text(budget.money(scheduledTotal))
                        .monospacedDigit()
                        .foregroundStyle(Flame.amountColor(scheduledTotal))
                }
            }
        }
        .toggleStyle(.button)
        .help("Show what is entered for later, above what has happened")
        .accessibilityIdentifier("scheduled-header")
    }

    private var title: String {
        switch scope {
        case .all: String(localized: "All Transactions")
        case let .account(account): account.name
        }
    }

    private var subtitle: String {
        switch scope {
        case .all: ""
        case let .account(account): "\(account.type.displayName) · \(account.currencyCode)"
        }
    }

    // MARK: - Reading

    /// Reads what the table needs. An account's register is read whole; every account together is
    /// read a page at a time, and searched in full only when asked.
    private func load() {
        let cutoff = budget.activityCutoff
        let uncategorized = Set(budget.uncategorized)
        let collapses = scope == .all
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()

        var scheduled: [LedgerTransaction] = []
        var settled: [LedgerTransaction] = []
        isTruncated = false

        switch (scope, filter) {
        case let (.account(account), _):
            let accountID = account.identifier
            // Split lines belong to their parent's row, so the register lists parents only.
            let all = ((try? modelContext.fetch(FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.account?.identifier == accountID && $0.parent == nil },
                sortBy: LedgerTransaction.newestFirst
            ))) ?? []).filter(\.isLive)
            let split = all.splitBySchedule(after: cutoff)
            (scheduled, settled) = (split.scheduled, split.settled)
            settledTotals = Self.totals(of: settled)

        case (.all, .toApprove):
            settled = (try? RecurrenceWriter.dueForApproval(in: modelContext, asOf: cutoff)) ?? []

        case (.all, .uncategorized):
            let wanted = budget.uncategorized
            settled = wanted.isEmpty ? [] : ((try? modelContext.fetch(FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { wanted.contains($0.identifier) },
                sortBy: LedgerTransaction.newestFirst
            ))) ?? [])

        case (.all, .everything):
            // Due entries are among the scheduled: their day has come, but they have not happened.
            scheduled = ((try? modelContext.fetch(FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { ($0.date > cutoff || $0.awaitsApproval) && $0.parent == nil },
                sortBy: LedgerTransaction.newestFirst
            ))) ?? []).collapsingTransferPairs()

            var recent = FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.date <= cutoff && $0.parent == nil && $0.awaitsApproval == false },
                sortBy: LedgerTransaction.newestFirst
            )
            // Searching has to look at everything — there is no other way to find a payee from 2019
            // — so only a search reads past the page. Fetched with room to spare otherwise, because
            // collapsing a transfer pair removes a row and the page should still be full afterwards.
            if needle.isEmpty { recent.fetchLimit = Self.pageSize * 2 }
            settled = ((try? modelContext.fetch(recent)) ?? []).collapsingTransferPairs()
            if needle.isEmpty, settled.count > Self.pageSize {
                settled = Array(settled.prefix(Self.pageSize))
                isTruncated = true
            }
        }

        scheduled = scheduled.filter(\.isLive)
        settled = settled.filter(\.isLive)
        scheduledCount = scheduled.count
        scheduledTotal = scheduled.reduce(0) { $0 + MinorUnits($1.amountMinor) }

        if !needle.isEmpty {
            scheduled = scheduled.filter { Self.matches($0, needle) }
            settled = settled.filter { Self.matches($0, needle) }
        }
        let showsScheduled = filter == .everything && (isScheduledExpanded || !needle.isEmpty)

        func shaped(_ transactions: [LedgerTransaction]) -> [LedgerRow] {
            let made = transactions.map {
                LedgerRow($0, collapsesTransfer: collapses && $0.isTransfer, budget: budget, uncategorized: uncategorized)
            }
            // Newest first is how they were fetched, entry order breaking ties within a day; only
            // a different choice of column needs sorting again.
            return sortOrder == [KeyPathComparator(\LedgerRow.date, order: .reverse)]
                ? made
                : made.sorted(using: sortOrder)
        }
        // What has not happened stays above what has, whichever way the table is sorted.
        rows = (showsScheduled ? shaped(scheduled) : []) + shaped(settled)
        selection = selection.filter { id in rows.contains { $0.id == id } }
    }

    /// Cleared and uncleared must add up to the working balance, so upcoming entries are left out of
    /// both. Summed in one pass.
    private static func totals(of settled: [LedgerTransaction]) -> (cleared: MinorUnits, uncleared: MinorUnits) {
        var cleared: MinorUnits = 0
        var uncleared: MinorUnits = 0
        for transaction in settled {
            if transaction.cleared == .uncleared {
                uncleared += MinorUnits(transaction.amountMinor)
            } else {
                cleared += MinorUnits(transaction.amountMinor)
            }
        }
        return (cleared, uncleared)
    }

    /// Payee, memo, category, account, or the digits of the amount.
    private static func matches(_ transaction: LedgerTransaction, _ needle: String) -> Bool {
        let fields = [
            transaction.payee?.displayName ?? "",
            transaction.transferCounterAccount?.name ?? "",
            transaction.memo,
            transaction.category?.displayName ?? "",
            transaction.account?.name ?? "",
        ]
        if fields.contains(where: { $0.lowercased().contains(needle) }) { return true }
        let digits = needle.filter(\.isNumber)
        return !digits.isEmpty && String(abs(transaction.amountMinor)).contains(digits)
    }
}

/// A labelled sum above the table.
private struct Figure: View {
    let title: String
    let amount: MinorUnits
    var emphasised = false

    @Environment(BudgetModel.self) private var budget

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(budget.money(amount))
                .font(emphasised ? .title2.weight(.semibold) : .title3)
                .monospacedDigit()
                .foregroundStyle(emphasised ? Flame.amountColor(amount) : .primary)
        }
    }
}
