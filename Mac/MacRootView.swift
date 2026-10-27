import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// What the sidebar can show. An account is held by its identifier, not the model: a selection
/// outlives a sync that replaces the object behind it.
enum SidebarItem: Hashable {
    case plan
    case transactions
    case reports
    case budgetCheck
    case account(UUID)

    /// Where a tapped reminder lands. The phone's Home and Accounts tabs have no screen of their
    /// own here: the sidebar is both.
    init(_ tab: AppTab) {
        switch tab {
        case .home, .plan, .accounts: self = .plan
        case .transactions: self = .transactions
        case .reports: self = .reports
        }
    }
}

struct MacRootView: View {
    let budget: BudgetModel
    @State private var selection: SidebarItem? = .plan
    /// A new entry asked for from the menu. A fresh token each time, so asking twice opens twice.
    @State private var newEntryRequest: UUID?
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.order) private var accounts: [Account]

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 250, ideal: 310, max: 400)
        } detail: {
            detail
        }
        .flameTinted()
        .budgetLifecycle(budget) { selection = SidebarItem($0) }
        .focusedSceneValue(\.windowActions, WindowActions(
            show: { selection = $0 },
            newTransaction: {
                // An account's register adds to that account; anywhere else, to the one used last.
                if case .account = selection {} else { selection = .transactions }
                newEntryRequest = UUID()
            },
            stepMonth: { months in
                budget.visibleMonth = budget.visibleMonth.adding(months: months)
                budget.refresh(in: modelContext)
            },
            thisMonth: {
                budget.visibleMonth = .current()
                budget.refresh(in: modelContext)
            }
        ))
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .plan, nil:
            PlanScreen()
        case .transactions:
            TransactionsScreen(scope: .all, newEntryRequest: $newEntryRequest)
        case .reports:
            ReportsView()
        case .budgetCheck:
            BudgetCheckView()
                .navigationTitle("Check your budget")
        case let .account(identifier):
            if let account = accounts.first(where: { $0.identifier == identifier }) {
                TransactionsScreen(scope: .account(account), newEntryRequest: $newEntryRequest)
            } else {
                // Deleted, or merged away by a sync, while it was showing.
                ContentUnavailableView("No account selected", systemImage: "creditcard")
            }
        }
    }
}
