import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

struct AccountsView: View {
    @Environment(CloudSync.self) private var cloud
    @Environment(BudgetModel.self) private var budget
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.order) private var accounts: [Account]
    /// Closed accounts start collapsed: they are history rather than something to act on.
    @State private var collapsedGroups: Set<String> = ["closed"]
    @State private var isAddingAccount = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Net Worth") {
                        Text(budget.money(budget.netWorth))
                            .font(.title3.weight(.semibold))
                    }
                }

                group(String(localized: "Budget"), accounts: cashAccounts, key: "budget")
                group(String(localized: "Credit Cards"), accounts: creditAccounts, key: "credit")
                group(String(localized: "Tracking"), accounts: tracking, key: "tracking")
                // A heading over many accounts, not one account's state: plural where languages inflect.
                group(String(localized: "accounts.closed", defaultValue: "Closed"), accounts: closed, key: "closed")
            }
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingAccount = true
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .accessibilityIdentifier("add-account")
                }
            }
            .sheet(isPresented: $isAddingAccount) { AddAccountView() }
            .overlay {
                // Empty because it is still arriving, not because there is nothing.
                if accounts.isEmpty, cloud.isFirstDownload {
                    FirstDownloadNotice(isProminent: true)
                } else if accounts.isEmpty {
                    ContentUnavailableView {
                        Label("No accounts yet", systemImage: "building.columns")
                    } description: {
                        Text("Import a YNAB export, or add an account to get started.")
                    } actions: {
                        Button("Add Account") { isAddingAccount = true }
                            .accessibilityIdentifier("add-first-account")
                    }
                }
            }
            .refreshable { budget.refresh(in: modelContext) }
        }
    }

    @ViewBuilder
    private func group(_ title: String, accounts: [Account], key: String) -> some View {
        if !accounts.isEmpty {
            Section {
                if !collapsedGroups.contains(key) {
                    ForEach(accounts) { account in
                        NavigationLink {
                            RegisterView(account: account)
                        } label: {
                            AccountRow(account: account)
                        }
                        .accessibilityIdentifier("account-row")
                    }
                    .onMove { offsets, destination in
                        reorder(accounts, from: offsets, to: destination)
                    }
                }
            } header: {
                Button {
                    withAnimation(.snappy) {
                        if collapsedGroups.contains(key) {
                            collapsedGroups.remove(key)
                        } else {
                            collapsedGroups.insert(key)
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(collapsedGroups.contains(key) ? 0 : 90))
                            // Points the way the text reads when folded, and down either way when open.
                            .flipsForRightToLeftLayoutDirection(true)
                            .foregroundStyle(Flame.ember)
                        Text(title)
                        Spacer()
                        Text(budget.money(budget.total(of: accounts)))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("account-group-\(key)")
            }
        }
    }

    private func reorder(_ section: [Account], from offsets: IndexSet, to destination: Int) {
        groups.reorder(section, from: offsets, to: destination, in: modelContext)
        budget.refresh(in: modelContext)
    }

    private var groups: AccountGroups { AccountGroups(accounts) }
    private var cashAccounts: [Account] { groups.cash }
    private var creditAccounts: [Account] { groups.credit }
    private var tracking: [Account] { groups.tracking }
    private var closed: [Account] { groups.closed }
}

struct AccountRow: View {
    let account: Account
    @Environment(BudgetModel.self) private var budget

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.name)
                    // On every account, not only foreign ones: two "Cash" accounts that differ
                    // only in currency are otherwise indistinguishable at a glance.
                    CurrencyBadge(code: account.currencyCode)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(budget.money(balance))
                .monospacedDigit()
                .fontWeight(.medium)
                .foregroundStyle(Flame.amountColor(balance))
        }
    }

    private var balance: MinorUnits { budget.balance(of: account) }

    /// The currency now sits beside the name as a badge, so the subtitle carries only the rest.
    private var subtitle: String {
        var parts = [account.type.displayName]
        if let fee = account.fxFeePercentOverride, fee != 0 {
            parts.append(String(localized: "FX fee \(fee.formatted(.number.locale(.display)))%"))
        }
        return parts.joined(separator: " · ")
    }
}
