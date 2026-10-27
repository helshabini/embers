import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// Where the bank's foreign-transaction fee is set.
///
/// The fee is charged when a card is used in a currency the account does not hold, so it belongs to
/// the account. A plan-wide default covers the common case of one bank, and accounts that charge
/// something different override it.
struct FXSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(BudgetModel.self) private var budget
    @Query(sort: \Account.order) private var accounts: [Account]

    @State private var defaultFeeText = ""
    @State private var quote: ExchangeRateQuote?
    @State private var isRefreshing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Plan currency", value: budget.baseCurrency.code)
            } footer: {
                Text("Everything is recorded in this currency, whatever you type it in.")
            }

            Section {
                HStack {
                    TextField("0", text: $defaultFeeText)
                        // Its row is labelled already; on the Mac a field's title would show beside it too.
                        .labelsHidden()
                        .decimalKeyboard()
                        .onChange(of: defaultFeeText) { _, new in save(new) }
                    Text("%").foregroundStyle(.secondary)
                }
            } header: {
                Text("Default foreign-transaction fee")
            } footer: {
                Text(
                    "Most banks add a percentage when you pay in a currency your account doesn't hold. Spending EGP on an AED card is charged this fee; spending AED on it is not."
                )
            }

            Section {
                if let quote {
                    LabeledContent("Source") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(quote.providerName)
                            RateAttribution(providerName: quote.providerName)
                        }
                    }
                    LabeledContent("Updated", value: quote.asOf.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: .display)))
                    LabeledContent("Currencies", value: quote.rates.count.formatted(.number.locale(.display)))
                } else {
                    Text("No rates stored yet").foregroundStyle(.secondary)
                }
                Button {
                    Task { await refresh(force: true) }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Text("Refresh Rates Now")
                    }
                }
                .disabled(isRefreshing)
            } header: {
                Text("Exchange rates")
            } footer: {
                Text(
                    "Rates are stored on the device so entering an amount works offline. The entry screen shows how old the rate is, and lets you type the bank's own rate instead."
                )
            }

            Section {
                ForEach(accountsWithForeignCurrency) { account in
                    NavigationLink {
                        AccountSettingsView(account: account)
                    } label: {
                        LabeledContent(account.name) {
                            Text(feeDescription(account)).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Only accounts held in a currency other than \(budget.baseCurrency.code) are listed.")
            }
        }
        .navigationTitle("Currency & FX")
        .inlineNavigationTitle()
        .onDisappear { try? modelContext.save() }
        .task {
            defaultFeeText = formatted(planDefaultFee)
            await refresh(force: false)
        }
    }

    private var accountsWithForeignCurrency: [Account] {
        accounts.filter { $0.currencyCode != budget.baseCurrency.code && !$0.closed }
    }

    private func feeDescription(_ account: Account) -> String {
        let fee = account.fxFeePercentOverride ?? planDefaultFee
        return "\(account.currencyCode) · \(formatted(fee))%"
    }

    private var planDefaultFee: Double {
        (try? modelContext.planSettings().defaultFXFeePercent) ?? 0
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Kept on the model as it is typed, written to the store on the way out. Saved per keystroke,
    /// each letter was a disk write and an upload to iCloud for a figure still being typed.
    private func save(_ text: String) {
        guard let settings = try? modelContext.planSettings() else { return }
        settings.defaultFXFeePercent = Double(text) ?? 0
    }

    private func refresh(force: Bool) async {
        isRefreshing = force
        defer { isRefreshing = false }
        if force {
            quote = await ExchangeRateService.refreshIfNeeded(
                baseCode: budget.baseCurrency.code,
                in: modelContext,
                force: true
            )
        } else {
            quote = try? ExchangeRateService.latestQuote(
                in: modelContext,
                baseCode: budget.baseCurrency.code
            )
        }
    }
}

struct AccountSettingsView: View {
    @Bindable var account: Account

    @Environment(\.modelContext) private var modelContext
    @Environment(BudgetModel.self) private var budget
    @State private var feeText = ""
    @State private var draftName = ""
    @State private var usesPlanDefault = true
    @State private var isConfirmingReconcile = false

    /// Writing straight to the model on every keystroke made typing crawl: each character triggered a
    /// save and every view watching the account rebuilt.
    private func syncCards() {
        budget.syncCreditCardCategories(in: modelContext)
    }

    /// What stands between this account and closing it. A closed account leaves every list, but its
    /// balance and a card's payment category keep counting: money nobody can see any more.
    private enum ClosingBlocker {
        case upcoming
        case uncleared
        case balance(MinorUnits)
        case setAside(MinorUnits)
    }

    private var closingBlocker: ClosingBlocker? {
        if budget.upcoming(of: account) != 0 { return .upcoming }
        let balance = budget.balance(of: account)
        if balance != 0 {
            // Reconciling settles the cleared balance; with uncleared rows it could not reach zero.
            let cleared = (try? ReconcileWriter.plan(for: account, statementBalanceMinor: 0, in: modelContext))?
                .clearedBalanceMinor
            return cleared.map { MinorUnits($0) == balance } == true ? .balance(balance) : .uncleared
        }
        let held = budget.heldForPayment(of: account)
        return held > 0 ? .setAside(held) : nil
    }

    private func explanation(of blocker: ClosingBlocker) -> String {
        let whereItGoes = account.onBudget
            ? String(localized: "The difference goes to Ready to Assign.")
            : String(localized: "The difference is written as an adjustment.")
        switch blocker {
        case .upcoming:
            return String(localized: "Transactions are still to come in this account. Delete them or move them to another account before closing it.")
        case .uncleared:
            return String(localized: "Some transactions here have not cleared. Clear or delete them before closing the account.")
        case let .balance(balance) where balance < 0:
            return String(localized: "This account still owes \(budget.money(-balance)). Pay it off, or reconcile it to zero before closing it.") + " " + whereItGoes
        case let .balance(balance):
            return String(localized: "This account still holds \(budget.money(balance)). Transfer it to another account, or reconcile it to zero before closing it.") + " " + whereItGoes
        case let .setAside(held):
            return String(localized: "Its payment category still holds \(budget.money(held)). Move it to Ready to Assign before closing the card: once it is closed, that category is hidden.")
        }
    }

    private func reconcileToZero() {
        try? ReconcileWriter.reconcile(account, statementBalanceMinor: 0, in: modelContext)
        budget.refresh(in: modelContext)
    }

    /// Into the current month, where the money is.
    private func releaseSetAside() {
        for category in account.paymentCategories ?? [] {
            let held = budget.result?.state(of: category.identifier, in: .current()).available ?? 0
            guard held > 0 else { continue }
            try? AssignmentWriter.adjustAssigned(by: -held, category: category, month: .current(), in: modelContext)
        }
        budget.refresh(in: modelContext)
    }

    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != account.name else { return }
        account.name = trimmed
        try? modelContext.save()
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draftName)
                    .onSubmit(commitName)
                Picker("Type", selection: $account.type) {
                    ForEach(AccountType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                Toggle("On budget", isOn: $account.onBudget)
                Toggle("Closed", isOn: $account.closed)
                    .disabled(!account.closed && closingBlocker != nil)
                    .accessibilityIdentifier("account-closed")
                if !account.closed {
                    switch closingBlocker {
                    case .balance:
                        Button("Reconcile to \(budget.money(0))") { isConfirmingReconcile = true }
                            .accessibilityIdentifier("reconcile-to-zero")
                    case let .setAside(held):
                        Button("Move \(budget.money(held)) to Ready to Assign", action: releaseSetAside)
                            .accessibilityIdentifier("release-set-aside")
                    case .upcoming, .uncleared, nil:
                        EmptyView()
                    }
                }
            } header: {
                Text("Account")
            } footer: {
                if !account.closed, let closingBlocker {
                    Text(explanation(of: closingBlocker))
                        .accessibilityIdentifier("closing-blocker")
                }
            }

            Section {
                NavigationLink {
                    CurrencyListView(selected: account.currencyCode) { account.currencyCode = $0 }
                } label: {
                    LabeledContent("Held in", value: account.currencyCode)
                }
            } footer: {
                Text(
                    "Paying in \(account.currencyCode) from this account is a domestic charge. Paying in anything else attracts the fee below."
                )
            }

            Section {
                Toggle("Use the plan default", isOn: $usesPlanDefault)
                    .onChange(of: usesPlanDefault) { _, usesDefault in
                        account.fxFeePercentOverride = usesDefault ? nil : (Double(feeText) ?? 0)
                        try? modelContext.save()
                    }
                if !usesPlanDefault {
                    HStack {
                        TextField("0", text: $feeText)
                            // Its row is labelled already; on the Mac a field's title would show beside it too.
                            .labelsHidden()
                            .decimalKeyboard()
                            .onChange(of: feeText) { _, new in
                                // Saved on the way out, by the refresh there, not per keystroke.
                                account.fxFeePercentOverride = Double(new) ?? 0
                            }
                        Text("%").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Foreign-transaction fee")
            }
        }
        .navigationTitle(account.name)
        .inlineNavigationTitle()
        .alert("Reconcile to \(budget.money(0))?", isPresented: $isConfirmingReconcile) {
            Button("Reconcile", action: reconcileToZero)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("An adjustment of \(budget.money(-budget.balance(of: account))) is written, so the account reads zero and can be closed.")
        }
        // Closing a card, reopening it, changing its type or its name all change what the credit
        // card group should hold, and it follows the accounts rather than being edited by hand.
        .onChange(of: account.closed) { _, _ in syncCards() }
        .onChange(of: account.type) { _, _ in syncCards() }
        .onDisappear {
            commitName()
            syncCards()
            budget.refresh(in: modelContext)
        }
        .task {
            usesPlanDefault = account.fxFeePercentOverride == nil
            feeText = account.fxFeePercentOverride.map { String($0) } ?? ""
            draftName = account.name
        }
    }
}

struct CurrencyListView: View {
    let selected: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        List {
            ForEach(matches, id: \.self) { code in
                Button {
                    onPick(code)
                    dismiss()
                } label: {
                    HStack {
                        Text(code)
                        if let name = CurrencyRegistry.currency(forCode: code).localizedName {
                            Text(name).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if code == selected { Image(systemName: "checkmark") }
                    }
                }
            }
        }
        .navigationTitle("Currency")
        .searchable(text: $searchText, prompt: "Code or name")
    }

    private var matches: [String] {
        guard !searchText.isEmpty else { return CurrencyRegistry.allCodes }
        let needle = searchText.lowercased()
        return CurrencyRegistry.allCodes.filter { code in
            code.lowercased().contains(needle)
                || (CurrencyRegistry.currency(forCode: code).localizedName?.lowercased().contains(needle) ?? false)
        }
    }
}
