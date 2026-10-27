import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// The phone's Home and Accounts tabs, folded into one column: Ready to Assign at the top, the
/// screens, then every account with its balance, as YNAB lays out its own sidebar.
struct SidebarView: View {
    @Environment(CloudSync.self) private var cloud
    @Binding var selection: SidebarItem?
    @Environment(BudgetModel.self) private var budget
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.order) private var accounts: [Account]
    /// Closed accounts start folded: they are history rather than something to act on.
    @AppStorage("sidebar.closedExpanded") private var closedExpanded = false
    @State private var isAddingAccount = false

    var body: some View {
        List(selection: $selection) {
            Section {
                // In place of Ready to Assign, which is not yet the budget's but whatever part of it
                // has arrived.
                if cloud.isFirstDownload {
                    if !accounts.isEmpty {
                        FirstDownloadNotice()
                            .padding(.vertical, 4)
                            .selectionDisabled()
                    }
                } else {
                    ReadyToAssignCard()
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 10, trailing: 0))
                        .selectionDisabled()
                }

                Label("Plan", systemImage: "list.bullet.rectangle")
                    .tag(SidebarItem.plan)
                    .accessibilityIdentifier("sidebar-plan")
                Label("All Transactions", systemImage: "arrow.left.arrow.right")
                    // What waits on a person: uncategorised entries and scheduled ones now due.
                    .badge(budget.needsAttentionCount)
                    .tag(SidebarItem.transactions)
                    .accessibilityIdentifier("sidebar-transactions")
                Label("Reports", systemImage: "chart.line.uptrend.xyaxis")
                    .tag(SidebarItem.reports)
                    .accessibilityIdentifier("sidebar-reports")
                // Only when it has found something: a clean check needs no place in the sidebar.
                if !budget.findings.isClear {
                    Label("Check your budget", systemImage: "stethoscope")
                        .badge(budget.findings.uncategorisedBoundaryTransfers.count)
                        .tag(SidebarItem.budgetCheck)
                        .accessibilityIdentifier("sidebar-budget-check")
                }
            }

            let groups = AccountGroups(accounts)
            group(String(localized: "Budget"), groups.cash, in: groups)
            group(String(localized: "Credit Cards"), groups.credit, in: groups)
            group(String(localized: "Tracking"), groups.tracking, in: groups)
            if !groups.closed.isEmpty {
                Section(isExpanded: $closedExpanded) {
                    rows(groups.closed, in: groups)
                } header: {
                    Text(String(localized: "accounts.closed", defaultValue: "Closed"))
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("sidebar")
        .safeAreaInset(edge: .bottom) { footer }
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
    }

    @ViewBuilder
    private func group(_ title: String, _ members: [Account], in groups: AccountGroups) -> some View {
        if !members.isEmpty {
            Section {
                rows(members, in: groups)
            } header: {
                HStack {
                    Text(title)
                    Spacer()
                    Text(budget.money(budget.total(of: members)))
                        .monospacedDigit()
                }
            }
        }
    }

    private func rows(_ members: [Account], in groups: AccountGroups) -> some View {
        ForEach(members) { account in
            SidebarAccountRow(account: account)
                .tag(SidebarItem.account(account.identifier))
                .accessibilityIdentifier("sidebar-account")
        }
        .onMove { offsets, destination in
            groups.reorder(members, from: offsets, to: destination, in: modelContext)
            budget.refresh(in: modelContext)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            // What iCloud is doing, in view whatever the window shows: a copy still filling up
            // should never look finished.
            if CloudSync.isEnabled {
                SyncStatusView()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            HStack {
                Text("Net Worth")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(budget.money(budget.netWorth))
                    .monospacedDigit()
                    .fontWeight(.medium)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            HStack {
                Button {
                    isAddingAccount = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("add-account")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .sheet(isPresented: $isAddingAccount) {
            AddAccountView()
                .formStyle(.grouped)
                .frame(minWidth: 460, minHeight: 520)
        }
    }
}

/// Ready to Assign, small enough for a sidebar and always in view whatever the window shows.
///
/// For the month the Plan is on, as the phone's card is: it is the Plan's question.
struct ReadyToAssignCard: View {
    @Environment(BudgetModel.self) private var budget

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Ready to Assign".uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                Spacer()
                Text(budget.visibleMonth.displayName)
                    .font(.caption2)
            }
            .foregroundStyle(.white.opacity(0.85))
            Text(budget.money(budget.readyToAssign))
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if !budget.uncategorized.isEmpty {
                // Money moved without a category is invisible to this figure; said where it is read.
                Label(
                    String(localized: "\(budget.uncategorized.count) uncategorized transactions", locale: .display),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Coloured by the one question it answers, as YNAB does: money left to give a job, none, or
    /// more given out than there is.
    private var background: LinearGradient {
        if budget.readyToAssign > 0 { return Flame.inflowGradient }
        return budget.readyToAssign < 0 ? Flame.outflowGradient : Flame.neutralGradient
    }
}

struct SidebarAccountRow: View {
    let account: Account
    @Environment(BudgetModel.self) private var budget

    var body: some View {
        HStack(spacing: 6) {
            Text(account.name)
                .lineLimit(1)
            // On every account, not only foreign ones: two "Cash" accounts that differ only in
            // currency are otherwise indistinguishable at a glance.
            CurrencyBadge(code: account.currencyCode)
            Spacer(minLength: 4)
            Text(budget.money(balance))
                .monospacedDigit()
                .foregroundStyle(balance < 0 ? Flame.outflow : .secondary)
                // The balance cannot be shortened; a long name can.
                .layoutPriority(1)
        }
    }

    private var balance: MinorUnits { budget.balance(of: account) }
}
