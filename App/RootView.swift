import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

struct RootView: View {
    @State private var budget = BudgetModel()
    @State private var tab = AppTab.home

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: .home) {
                HomeView()
            }
            Tab("Plan", systemImage: "list.bullet.rectangle", value: .plan) {
                PlanView()
            }
            Tab("Transactions", systemImage: "arrow.left.arrow.right", value: .transactions) {
                TransactionsView()
            }
            // Uncategorised entries and scheduled ones whose day has come: both wait on a person,
            // and a scheduled payment that went unnoticed is what this is here to prevent.
            .badge(budget.needsAttentionCount)
            Tab("Accounts", systemImage: "creditcard", value: .accounts) {
                AccountsView()
            }
            Tab("Reports", systemImage: "chart.line.uptrend.xyaxis", value: .reports) {
                ReportsView()
            }
        }
        .flameTinted()
        .budgetLifecycle(budget) { tab = $0 }
    }
}

struct HomeView: View {
    @Environment(CloudSync.self) private var cloud
    @Environment(BudgetModel.self) private var budget
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.order) private var accounts: [Account]
    @AppStorage("lastAccountIdentifier") private var lastAccountIdentifier = ""
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            List {
                // Above the figures, which are only what has arrived so far.
                if cloud.isFirstDownload, !accounts.isEmpty {
                    Section { FirstDownloadNotice() }
                }
                Section {
                    LabeledContent("Ready to Assign") {
                        Text(budget.money(budget.readyToAssign))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(budget.readyToAssign < 0 ? .red : .primary)
                    }
                    LabeledContent("Net Worth", value: budget.money(budget.netWorth))
                } header: {
                    Text(budget.visibleMonth.displayName)
                }

                if !accounts.isEmpty {
                    Section("Accounts") {
                        LabeledContent("On budget", value: budget.money(budget.total(of: onBudget)))
                        LabeledContent("Tracking", value: budget.money(budget.total(of: tracking)))
                    }
                }

                if let error = budget.lastError {
                    Section("Problem") {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Embers")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        MoreView()
                    } label: {
                        Label("More", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("open-more")
                }
            }
            .overlay {
                // Empty because it is still arriving, not because there is nothing.
                if accounts.isEmpty, cloud.isFirstDownload {
                    FirstDownloadNotice(isProminent: true)
                } else if accounts.isEmpty {
                    ContentUnavailableView(
                        "No accounts yet",
                        systemImage: "tray",
                        description: Text("Import a YNAB export or add an account to get started.")
                    )
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // Home is where the app opens, so a purchase can be written down from the first
                // screen rather than after a trip to the Transactions tab.
                if !accounts.isEmpty {
                    FloatingAddButton { isAdding = true }
                        .accessibilityIdentifier("add-transaction-home")
                }
            }
            .refreshable { budget.refresh(in: modelContext) }
            .sheet(isPresented: $isAdding) {
                TransactionEditorView(account: lastUsedAccount, existing: nil)
            }
        }
    }

    /// The account last written to, as on the Transactions tab, so an entry opens where the last
    /// one went.
    private var lastUsedAccount: Account? {
        accounts.first { $0.identifier.uuidString == lastAccountIdentifier && !$0.closed }
            ?? accounts.first { !$0.closed }
    }

    private var onBudget: [Account] { accounts.filter { $0.onBudget && !$0.closed } }
    private var tracking: [Account] { accounts.filter { !$0.onBudget && !$0.closed } }
}
