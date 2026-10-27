import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// Entering or editing a transaction, in the inspector beside the table.
///
/// The phone's editor and this one are two screens over one `TransactionDraft`, so a transfer,
/// a conversion or a repeat is written the same way from either. What differs is only the input:
/// the amount is typed rather than tapped out on a keypad, and every choice is a menu.
struct TransactionEditor: View {
    /// The draft is made once per editor; a different transaction is a different editor, by `.id`.
    @State private var draft: TransactionDraft
    /// Saved or deleted: the screen decides what comes next.
    let onFinish: (_ savedTo: Account?) -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(BudgetModel.self) private var budget
    @Query(sort: \Account.order) private var accounts: [Account]
    @Query(sort: \Payee.name) private var payees: [Payee]
    @Query(sort: \BudgetCategoryModel.order) private var categories: [BudgetCategoryModel]

    @State private var amountText = ""
    @State private var isChoosingCurrency = false
    @State private var isConfirmingDelete = false
    /// Read on the click: the alert re-renders its message while closing, after the row is gone.
    @State private var deletionSummary = ""
    @FocusState private var focus: Field?
    @AppStorage("recentCurrencyCodes") private var recentCurrencies = ""
    @AppStorage("lastAccountIdentifier") private var lastAccountIdentifier = ""

    private enum Field: Hashable { case amount, payee }

    init(
        account: Account?,
        existing: LedgerTransaction?,
        onFinish: @escaping (_ savedTo: Account?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: TransactionDraft(account: account, existing: existing))
        self.onFinish = onFinish
        self.onCancel = onCancel
    }

    var body: some View {
        // Deleted under the editor — from the table, or by another device.
        if let existing = draft.existing, !existing.isLive {
            ContentUnavailableView("No transaction selected", systemImage: "arrow.left.arrow.right")
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                accountPicker(String(localized: "Account"), selection: accountBinding, excluding: nil)
                    .accessibilityIdentifier("account-picker")
                if draft.existing == nil {
                    Toggle("Transfer between accounts", isOn: $draft.isTransfer)
                        .accessibilityIdentifier("transfer-toggle")
                }
            }

            amountSection

            if draft.isTransfer { transferSection } else { payeeSection }

            Section {
                DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                    .datePickerStyle(.field)
                Picker("Repeats", selection: $draft.recurrence) {
                    // Its own key: "Never" alone reads, in Arabic, as "at no time" rather than "does not repeat".
                    Text(String(localized: "repeat.never", defaultValue: "Never")).tag(Recurrence?.none)
                    ForEach(Recurrence.allCases, id: \.self) { rule in
                        Text(rule.displayName).tag(Recurrence?.some(rule))
                    }
                }
                TextField("Memo", text: $draft.memo, axis: .vertical)
                clearedRow
            } footer: {
                if let repeatNote = draft.repeatNote { note(repeatNote) }
            }

            Section {
                buttons
            }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.title)
        .task { prepare() }
        .task { await draft.refreshRateInBackground(base: budget.baseCurrency, in: modelContext) }
        .alert("Delete this transaction?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                draft.delete(budget: budget, in: modelContext)
                onFinish(nil)
            }
        } message: {
            Text(deletionSummary)
        }
    }

    // MARK: - Amount

    @ViewBuilder
    private var amountSection: some View {
        if let entry = draft.entry {
            Section {
                HStack(spacing: 8) {
                    Button {
                        isChoosingCurrency = true
                    } label: {
                        HStack(spacing: 3) {
                            Text(entry.enteredCurrency.code)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                    }
                    .accessibilityIdentifier("currency-picker")
                    .help("The currency this was paid in")
                    .popover(isPresented: $isChoosingCurrency, arrowEdge: .bottom) {
                        CurrencyList(
                            selected: entry.enteredCurrency.code,
                            suggested: entry.suggestedCurrencyCodes(recent: recentCurrencyCodes)
                        ) { code in
                            draft.choose(currencyCode: code)
                            rememberCurrency(code)
                            enterAmount(amountText)
                            isChoosingCurrency = false
                        }
                    }

                    TextField("Amount", text: $amountText, prompt: Text(verbatim: "0.00"))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .amount)
                        .onChange(of: amountText) { _, text in enterAmount(text) }
                        .accessibilityIdentifier("amount-field")
                }

                Picker("Direction", selection: $draft.isOutflow) {
                    Text(draft.isTransfer ? String(localized: "From") : String(localized: "Outflow")).tag(true)
                    Text(draft.isTransfer ? String(localized: "To") : String(localized: "Inflow")).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if !entry.isPlainBaseCurrencyEntry {
                    LabeledContent(budget.baseCurrency.code) {
                        Text(draft.convertedSummary(base: budget.baseCurrency))
                            .monospacedDigit()
                            .foregroundStyle(entry.isOutflow ? Flame.outflow : Flame.inflow)
                    }
                }
                // Without a rate there is nothing to convert, so one has to come from somewhere.
                if entry.isMissingRate {
                    TextField("Rate to \(budget.baseCurrency.code)", text: $draft.manualRateText)
                }
            } footer: {
                if entry.isMissingRate {
                    note(String(localized: "No stored rate for \(entry.enteredCurrency.code). Enter what your bank used."))
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        note(draft.rateNote(base: budget.baseCurrency))
                        if !entry.isPlainBaseCurrencyEntry { RateAttribution(providerName: entry.quote?.providerName) }
                    }
                }
            }
        }
    }

    /// Typed text into the entry. Digits beyond the currency's own are rounded by the parser; a
    /// minus sign means nothing here, since the direction is chosen beside it.
    private func enterAmount(_ text: String) {
        guard let currency = draft.entry?.enteredCurrency else { return }
        let parsed = Money.parse(text, currency: currency)?.minorUnits ?? 0
        // The phone's keypad stops at fifteen digits, so a stuck key cannot overflow the ledger.
        guard abs(parsed) < 1_000_000_000_000_000 else { return }
        draft.entry?.setEnteredAmount(abs(parsed))
    }

    // MARK: - Payee, category, transfer

    private var payeeSection: some View {
        Section {
            TextField("Payee", text: $draft.payeeName)
                .focused($focus, equals: .payee)
                .textInputSuggestions {
                    ForEach(PayeeMemory.suggestions(matching: draft.payeeName, among: payees), id: \.identifier) { payee in
                        Text(payee.displayName).textInputCompletion(payee.name)
                    }
                }
                .onChange(of: draft.payeeName) { _, _ in
                    draft.fillCategoryFromPayee(payees: payees, in: modelContext)
                }
                .accessibilityIdentifier("payee-field")
            categoryPicker
        }
    }

    private var transferSection: some View {
        Section {
            // The other account is where the money goes when this one pays out, and where it came
            // from when this one receives.
            accountPicker(
                draft.isOutflow ? String(localized: "To account") : String(localized: "From account"),
                selection: Binding(
                    get: { draft.transferDestination?.identifier },
                    set: { id in draft.transferDestination = accounts.first { $0.identifier == id } }
                ),
                excluding: draft.account
            )
            if draft.destinationNeedsCategory { categoryPicker }
        } footer: {
            note(draft.transferNote)
        }
    }

    /// Grouped as the plan is, so a long list reads in the order it is planned. Typing in an open
    /// menu jumps to the name, as every Mac menu does.
    private var categoryPicker: some View {
        Picker("Category", selection: Binding(
            get: { draft.category?.identifier },
            set: { id in draft.choose(category: categories.first { $0.identifier == id }) }
        )) {
            Text("None").tag(UUID?.none)
            ForEach(groupedCategories, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.categories, id: \.identifier) { category in
                        Text(category.displayName).tag(UUID?.some(category.identifier))
                    }
                }
            }
        }
        .accessibilityIdentifier("category-picker")
    }

    private func accountPicker(_ title: String, selection: Binding<UUID?>, excluding: Account?) -> some View {
        Picker(title, selection: selection) {
            if selection.wrappedValue == nil {
                Text("Choose…").tag(UUID?.none)
            }
            let open = accounts.filter { !$0.closed && $0.identifier != excluding?.identifier }
            Section("On budget") {
                ForEach(open.filter(\.onBudget), id: \.identifier) { account in
                    Text(verbatim: "\(account.name)  \(account.currencyCode)").tag(UUID?.some(account.identifier))
                }
            }
            Section("Tracking") {
                ForEach(open.filter { !$0.onBudget }, id: \.identifier) { account in
                    Text(verbatim: "\(account.name)  \(account.currencyCode)").tag(UUID?.some(account.identifier))
                }
            }
        }
    }

    private var accountBinding: Binding<UUID?> {
        Binding(
            get: { draft.account?.identifier },
            set: { id in
                guard let chosen = accounts.first(where: { $0.identifier == id }) else { return }
                draft.choose(account: chosen, planFeePercent: TransactionDraft.planFeePercent(in: modelContext))
                enterAmount(amountText)
            }
        )
    }

    /// Cleared is a yes or a no. Reconciled is not one to set by hand — it means checked against a
    /// statement — so it shows locked rather than disappearing.
    @ViewBuilder
    private var clearedRow: some View {
        if draft.cleared == .reconciled {
            LabeledContent("Cleared") {
                Label("Reconciled", systemImage: "lock.fill").foregroundStyle(.secondary)
            }
        } else {
            Toggle("Cleared", isOn: $draft.isCleared)
                .accessibilityIdentifier("cleared-toggle")
        }
    }

    private var buttons: some View {
        HStack {
            if let existing = draft.existing {
                Button("Delete…", role: .destructive) {
                    deletionSummary = TransactionWriter.deletionSummary(existing, in: modelContext)
                    isConfirmingDelete = true
                }
                .accessibilityIdentifier("delete-transaction")
            }
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.canSave)
                .accessibilityIdentifier("save-transaction")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Lists

    private struct CategoryGroupChoice {
        let name: String
        var categories: [BudgetCategoryModel]
    }

    private var groupedCategories: [CategoryGroupChoice] {
        var grouped: [CategoryGroupChoice] = []
        var index: [String: Int] = [:]
        for candidate in categories.selectable {
            let name = candidate.group?.displayName ?? ""
            if let at = index[name] {
                grouped[at].categories.append(candidate)
            } else {
                index[name] = grouped.count
                grouped.append(CategoryGroupChoice(name: name, categories: [candidate]))
            }
        }
        return grouped
    }

    private var recentCurrencyCodes: [String] {
        recentCurrencies.split(separator: ",").map(String.init)
    }

    private func rememberCurrency(_ code: String) {
        guard code != draft.account?.currencyCode, code != budget.baseCurrency.code else { return }
        var codes = recentCurrencyCodes.filter { $0 != code }
        codes.insert(code, at: 0)
        recentCurrencies = codes.prefix(4).joined(separator: ",")
    }

    // MARK: - Loading and saving

    private func prepare() {
        guard !draft.isPrepared else { return }
        draft.prepare(accounts: accounts, lastAccountIdentifier: lastAccountIdentifier, budget: budget, in: modelContext)
        if let entry = draft.entry, !entry.isEmpty {
            amountText = entry.enteredMoney.formatted(showCurrencySymbol: false)
        }
        // A new entry starts where it is typed: the amount.
        if draft.existing == nil { focus = .amount }
    }

    private func save() {
        guard draft.canSave, let account = draft.save(payees: payees, budget: budget, in: modelContext) else { return }
        lastAccountIdentifier = account.identifier.uuidString
        onFinish(account)
    }
}

/// Every currency, searchable, with the likely ones first.
private struct CurrencyList: View {
    let selected: String
    let suggested: [String]
    let onPick: (String) -> Void

    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Code or name", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List {
                if searchText.isEmpty, !suggested.isEmpty {
                    Section("Likely") { ForEach(suggested, id: \.self) { row($0) } }
                }
                Section(searchText.isEmpty ? String(localized: "All currencies") : String(localized: "Results")) {
                    ForEach(matches, id: \.self) { row($0) }
                }
            }
        }
        .frame(width: 280, height: 360)
    }

    private func row(_ code: String) -> some View {
        Button {
            onPick(code)
        } label: {
            HStack {
                Text(code).fontWeight(.medium)
                if let name = CurrencyRegistry.currency(forCode: code).localizedName {
                    Text(name).foregroundStyle(.secondary)
                }
                Spacer()
                if code == selected { Image(systemName: "checkmark").foregroundStyle(Flame.ember) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("currency-\(code)")
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
