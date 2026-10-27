import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// Every account's transactions in one list, with a button to add one straight away.
///
/// Adding from here opens on the account used last, so the common case — another purchase on the same
/// card — takes one tap rather than first choosing where it happened.
struct TransactionsView: View {
    @Environment(CloudSync.self) private var cloud
    @Environment(BudgetModel.self) private var budget
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.order) private var accounts: [Account]

    /// The rows on screen, fetched rather than queried.
    ///
    /// A `@Query` here read every transaction in the budget — ten thousand of them — on the first
    /// open and again whenever anything changed, which is about a tenth of a second on a Mac and
    /// several times that on a phone, all on the main thread. Only a few hundred can be read at
    /// once, so only a few hundred are fetched: the same list, 27 times faster to produce.
    @State private var settled: [LedgerTransaction] = []
    @State private var scheduled: [LedgerTransaction] = []
    @State private var totalCount = 0
    @State private var isLoaded = false

    /// How many of the newest entries to show before asking the reader to search.
    private static let pageSize = 300

    @State private var searchText = ""
    /// Every settled entry with the text a search is matched against, read once when a search
    /// starts and then filtered in memory. Rebuilt from the store on each keystroke, a search
    /// read the whole register and faulted in every payee and category per letter typed.
    @State private var searchIndex: [Searchable]?

    private struct Searchable {
        let transaction: LedgerTransaction
        /// Payee, memo, category and account, lowercased, kept apart so a match cannot straddle two.
        let text: String
        let amount: String
    }
    /// Shared with the register, so folding the scheduled entries away is one decision, not two.
    @AppStorage("scheduledExpanded") private var isScheduledExpanded = false
    /// One sheet: stacking two on the same view means only one of them works.
    @State private var sheet: Sheet?

    private enum Sheet: Identifiable {
        case adding
        case editing(LedgerTransaction)

        var id: String {
            switch self {
            case .adding: "adding"
            // Not the transaction's identifier: SwiftUI asks for this again while the sheet is
            // dismissing, which after a delete is a read of a destroyed row, and that is fatal.
            case let .editing(transaction): "\(ObjectIdentifier(transaction))"
            }
        }
    }
    @AppStorage("lastAccountIdentifier") private var lastAccountIdentifier = ""

    var body: some View {
        NavigationStack {
            Group {
                if cloud.isFirstDownload && totalCount == 0 {
                    // Empty because it is still arriving, not because there is nothing.
                    FirstDownloadNotice(isProminent: true)
                } else if isLoaded && totalCount == 0 {
                    ContentUnavailableView(
                        "No transactions yet",
                        systemImage: "arrow.left.arrow.right",
                        description: Text("Add one with the button below, or import a YNAB export.")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Transactions")
            .searchable(text: $searchText, prompt: "Payee, memo, category or amount")
            .overlay(alignment: .bottomTrailing) { addButton }
            .task(id: searchText) {
                // A pause before searching, so a word typed quickly is one search, not one per
                // letter. Each new letter cancels the wait for the last. Clearing is immediate.
                if !searchText.isEmpty {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                }
                load()
            }
            .onChange(of: budget.revision) { _, _ in
                searchIndex = nil
                load()
            }
            .sheet(item: $sheet) { which in
                switch which {
                case .adding:
                    TransactionEditorView(account: lastUsedAccount, existing: nil)
                case let .editing(transaction):
                    // The editor reads the account from the transaction itself, once. Reading it here
                    // happens again as the sheet closes, by when a deleted row can no longer answer.
                    TransactionEditorView(account: nil, existing: transaction)
                }
            }
        }
    }

    private var list: some View {
        List {
            if budget.dueForApprovalCount > 0 || !budget.uncategorized.isEmpty {
                // Up top, where they are seen: each waits on a decision, and until it is made the
                // plan is not telling the whole story.
                Section {
                    if budget.dueForApprovalCount > 0 {
                        NavigationLink {
                            ApprovalListView()
                        } label: {
                            AttentionLabel(
                                title: String(localized: "\(budget.dueForApprovalCount) to approve", locale: .display),
                                systemImage: "clock.badge.exclamationmark"
                            )
                        }
                        .accessibilityIdentifier("to-approve")
                    }
                    if !budget.uncategorized.isEmpty {
                        NavigationLink {
                            UncategorizedListView()
                        } label: {
                            AttentionLabel(
                                title: String(localized: "\(budget.uncategorized.count) uncategorized transactions", locale: .display),
                                systemImage: "questionmark.folder"
                            )
                        }
                        .accessibilityIdentifier("uncategorized")
                    }
                }
            }

            if !scheduled.isEmpty {
                Section {
                    if isScheduledExpanded {
                        // Named apart from the settled rows so a test can say whether the section is
                        // open, rather than counting rows and being told what a lazy list happened
                        // to render.
                        ForEach(scheduled.filter(\.isLive)) { row($0).accessibilityIdentifier("scheduled-row") }
                    }
                } header: {
                    ScheduledHeader(count: scheduled.count, isExpanded: $isScheduledExpanded)
                }
            }

            Section {
                // The fetched rows are a copy, refreshed one update after a delete. Rendering that
                // update with the deleted row still in it read a destroyed model and crashed.
                ForEach(settled.filter(\.isLive)) { row($0) }
            }
            if settled.count >= Self.pageSize {
                Text("Showing the most recent \(Self.pageSize). Search to narrow it down.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // Keeps the last row clear of the floating button.
            Color.clear
                .frame(height: 56)
                .listRowBackground(Color.clear)
        }
    }

    /// One row, wherever it sits.
    @ViewBuilder
    private func row(_ transaction: LedgerTransaction) -> some View {
        Button {
            sheet = .editing(transaction)
        } label: {
            TransactionRow(
                transaction: transaction,
                showsAccount: true,
                collapsesTransfer: transaction.isTransfer
            )
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

    private var addButton: some View {
        FloatingAddButton { sheet = .adding }
            .accessibilityIdentifier("add-transaction-floating")
    }

    private var lastUsedAccount: Account? {
        accounts.first { $0.identifier.uuidString == lastAccountIdentifier && !$0.closed }
            ?? accounts.first { !$0.closed }
    }

    /// Split lines belong to their parent's row, so only parents are listed. Entries awaiting approval
    /// are not either: they have not happened, and the row up top leads to them.
    /// Reads what the screen needs, and no more.
    ///
    /// Two bounded fetches rather than one unbounded one: what has not happened yet, which is a
    /// handful of rows, and the newest few hundred that have. Searching still has to look at
    /// everything — there is no other way to find a payee from 2019 — so it only does so when the
    /// reader asks, instead of on every open.
    private func load() {
        let cutoff = budget.activityCutoff
        var upcoming = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.date > cutoff && $0.parent == nil },
            sortBy: LedgerTransaction.newestFirst
        )
        upcoming.fetchLimit = Self.pageSize
        scheduled = ((try? modelContext.fetch(upcoming)) ?? []).collapsingTransferPairs()

        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty {
            var recent = FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.date <= cutoff && $0.parent == nil && $0.awaitsApproval == false },
                sortBy: LedgerTransaction.newestFirst
            )
            // Fetched with room to spare, because collapsing a transfer pair removes a row and the
            // page should still be full afterwards.
            recent.fetchLimit = Self.pageSize * 2
            settled = Array(
                ((try? modelContext.fetch(recent)) ?? [])
                    .collapsingTransferPairs()
                    .prefix(Self.pageSize)
            )
            searchIndex = nil
        } else {
            settled = Array(matches(needle).prefix(Self.pageSize))
        }

        totalCount = (try? modelContext.fetchCount(
            FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.parent == nil })
        )) ?? 0
        isLoaded = true
    }

    /// Everything matching, oldest included. The one case that has to read the whole register —
    /// once per search, not once per letter.
    private func matches(_ needle: String) -> [LedgerTransaction] {
        let index = searchIndex ?? buildSearchIndex()
        searchIndex = index
        let digits = needle.filter(\.isNumber)
        return index.filter { entry in
            entry.text.contains(needle) || (!digits.isEmpty && entry.amount.contains(digits))
        }
        .map(\.transaction)
        // The index outlives a delete until the recompute that follows it; pairing reads the row.
        .filter(\.isLive)
        .collapsingTransferPairs()
    }

    private func buildSearchIndex() -> [Searchable] {
        let cutoff = budget.activityCutoff
        let all = (try? modelContext.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.date <= cutoff && $0.parent == nil && $0.awaitsApproval == false },
                sortBy: LedgerTransaction.newestFirst
            )
        )) ?? []
        return all.map { transaction in
            let fields = [
                transaction.payee?.displayName ?? "",
                transaction.memo,
                transaction.category?.displayName ?? "",
                transaction.account?.name ?? "",
            ]
            return Searchable(
                transaction: transaction,
                text: fields.joined(separator: "\n").lowercased(),
                amount: String(abs(transaction.amountMinor))
            )
        }
    }
}
