import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// Entering a transaction.
///
/// The account comes first because it decides everything below it: which currency is assumed, and
/// whether paying in another one attracts the bank's fee. What is held and how it is saved is
/// `TransactionDraft`, shared with the Mac; the arithmetic itself lives in `AmountEntry`, a value
/// type checked without a simulator.
struct TransactionEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(BudgetModel.self) private var budget

    @Query(sort: \Account.order) private var accounts: [Account]
    @Query(sort: \Payee.name) private var payees: [Payee]
    @Query(sort: \BudgetCategoryModel.order) private var categories: [BudgetCategoryModel]

    @State private var draft: TransactionDraft
    @State private var isChoosingCurrency = false
    @State private var isKeypadShowing = true
    @State private var payeeSuggestions: [Payee] = []
    @State private var isConfirmingDelete = false
    /// Read on the tap: the alert re-renders its message while closing, after the row is gone.
    @State private var deletionSummary = ""
    @FocusState private var focusedField: Field?
    @AppStorage("recentCurrencyCodes") private var recentCurrencies = ""
    @AppStorage("lastAccountIdentifier") private var lastAccountIdentifier = ""

    private enum Field: Hashable { case payee, memo, rate }

    init(account: Account?, existing: LedgerTransaction?) {
        _draft = State(initialValue: TransactionDraft(account: account, existing: existing))
    }

    private var existing: LedgerTransaction? { draft.existing }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    accountSection
                    amountSection
                    if draft.isTransfer { transferSection } else { payeeSection }
                    detailsSection
                }
                .onChange(of: focusedField) { _, field in
                    updatePayeeSuggestions()
                    guard let field else { return }
                    // Put away, not just hidden behind the keyboard. Hidden, it came straight back
                    // when the keyboard went — after a payee was chosen, even if it had been closed.
                    isKeypadShowing = false
                    guard field == .payee else { return }
                    // The suggestions are listed under the field, and the keyboard covered them.
                    // After the keyboard has risen, or the form's own scroll to the field undoes it.
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        withAnimation(.snappy) { proxy.scrollTo(Field.payee, anchor: .top) }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                // Hidden while a text field has focus: the system keyboard is already there, and two
                // keyboards stacked left no room to see the suggestions being typed against.
                if isKeypadShowing, focusedField == nil, draft.entry != nil {
                    Keypad(
                        onDigit: { draft.entry?.append(digit: $0) },
                        onDelete: { draft.entry?.deleteLastDigit() },
                        onClear: { draft.entry?.clear() },
                        onDone: { withAnimation(.snappy) { isKeypadShowing = false } }
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .background(.bar)
                    .transition(.move(edge: .bottom))
                }
            }
            .navigationTitle(draft.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!draft.canSave)
                        .fontWeight(.semibold)
                }
                if existing != nil {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Delete Transaction", role: .destructive) {
                            if let existing {
                                deletionSummary = TransactionWriter.deletionSummary(existing, in: modelContext)
                            }
                            isConfirmingDelete = true
                        }
                            .foregroundStyle(Flame.outflow)
                            .accessibilityIdentifier("delete-transaction")
                    }
                }
            }
            .sheet(isPresented: $isChoosingCurrency) {
                if let entry = draft.entry {
                    CurrencyPickerView(
                        selected: entry.enteredCurrency.code,
                        suggested: entry.suggestedCurrencyCodes(recent: recentCurrencyCodes)
                    ) { code in
                        draft.choose(currencyCode: code)
                        rememberCurrency(code)
                    }
                }
            }
            .alert("Delete this transaction?", isPresented: $isConfirmingDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { deleteTransaction() }
            } message: {
                Text(deletionSummary)
            }
            .task { prepare() }
            .task { await draft.refreshRateInBackground(base: budget.baseCurrency, in: modelContext) }
        }
        .flameTinted()
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            NavigationLink {
                AccountPickerView(accounts: openAccounts, selected: draft.account) { chosen in
                    draft.choose(account: chosen, planFeePercent: TransactionDraft.planFeePercent(in: modelContext))
                }
            } label: {
                LabeledContent("Account") {
                    HStack(spacing: 6) {
                        Text(draft.account?.name ?? String(localized: "Choose…"))
                        if let account = draft.account {
                            CurrencyBadge(code: account.currencyCode)
                        }
                    }
                }
            }
            .accessibilityIdentifier("account-picker")

            if existing == nil {
                Toggle("Transfer between accounts", isOn: $draft.isTransfer.animation(.snappy))
            }
        }
    }

    // MARK: - Amount

    @ViewBuilder
    private var amountSection: some View {
        if let entry = draft.entry {
            Section {
                VStack(spacing: 14) {
                    Button {
                        isChoosingCurrency = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(entry.enteredCurrency.code)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.22), in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("currency-picker")
                    .accessibilityLabel(entry.enteredCurrency.code)

                    Button {
                        focusedField = nil
                        withAnimation(.snappy) { isKeypadShowing.toggle() }
                    } label: {
                        VStack(spacing: 4) {
                            Text(entry.enteredMoney.formatted())
                                .font(.system(size: 42, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .minimumScaleFactor(0.5)
                                .lineLimit(1)
                                .contentTransition(.numericText())
                                .foregroundStyle(.white)
                            if !entry.isPlainBaseCurrencyEntry {
                                Text(draft.convertedSummary(base: budget.baseCurrency))
                                    .font(.footnote)
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)

                    Picker("Direction", selection: $draft.isOutflow) {
                        Text(draft.isTransfer ? String(localized: "From") : String(localized: "Outflow")).tag(true)
                        Text(draft.isTransfer ? String(localized: "To") : String(localized: "Inflow")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .colorScheme(.dark)
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(entry.isOutflow ? AnyShapeStyle(Flame.gradient) : AnyShapeStyle(Flame.inflowGradient))
                        .shadow(
                            color: (entry.isOutflow ? Flame.ember : Flame.inflow).opacity(0.3),
                            radius: 10, y: 5
                        )
                        .padding(.vertical, 4)
                        .animation(.snappy, value: entry.isOutflow)
                )
            } footer: {
                Text(RateAttribution.note(
                    draft.rateNote(base: budget.baseCurrency),
                    crediting: entry.isPlainBaseCurrencyEntry ? nil : entry.quote?.providerName
                ))
            }

            // Without a rate there is nothing to convert, so one has to come from somewhere.
            if entry.isMissingRate {
                Section {
                    TextField("Rate to \(budget.baseCurrency.code)", text: $draft.manualRateText)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .rate)
                } footer: {
                    Text("No stored rate for \(entry.enteredCurrency.code). Enter what your bank used.")
                }
            }
        }
    }

    // MARK: - Payee, category, transfer

    private var payeeSection: some View {
        Section {
            TextField("Payee", text: $draft.payeeName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .payee)
                .accessibilityIdentifier("payee-field")
                .id(Field.payee)
                .onChange(of: draft.payeeName) { _, _ in
                    updatePayeeSuggestions()
                    draft.fillCategoryFromPayee(payees: payees, in: modelContext)
                }
            ForEach(payeeSuggestions, id: \.identifier) { payee in
                Button {
                    draft.payeeName = payee.name
                    focusedField = nil
                    draft.fillCategoryFromPayee(force: true, payees: payees, in: modelContext)
                } label: {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(Flame.ember)
                        Text(payee.displayName)
                        Spacer()
                    }
                    // The whole row, not just the name: a tap beside it otherwise did nothing.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("payee-suggestion")
            }
            categoryLink
        }
    }

    private var categoryLink: some View {
        NavigationLink {
            CategoryPickerView(categories: categories.selectable, selected: draft.category) { chosen in
                draft.choose(category: chosen)
            }
        } label: {
            LabeledContent("Category") {
                Text(draft.category.map { "\($0.group?.displayName ?? ""): \($0.displayName)" } ?? String(localized: "None"))
                    .foregroundStyle(draft.category == nil ? .secondary : .primary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityIdentifier("category-picker")
    }

    private var transferSection: some View {
        Section {
            NavigationLink {
                AccountPickerView(
                    accounts: openAccounts.filter { $0.identifier != draft.account?.identifier },
                    selected: draft.transferDestination
                ) { draft.transferDestination = $0 }
            } label: {
                // The other account is where the money goes when this one pays out, and where it came from
                // when this one receives.
                LabeledContent(
                    draft.isOutflow ? String(localized: "To account") : String(localized: "From account"),
                    value: draft.transferDestination?.name ?? String(localized: "Choose…")
                )
            }
            if draft.destinationNeedsCategory { categoryLink }
        } footer: {
            Text(draft.transferNote)
        }
    }

    private var detailsSection: some View {
        Section {
            DatePicker("Date", selection: $draft.date, displayedComponents: .date)
            Picker("Repeats", selection: $draft.recurrence) {
                // Its own key: "Never" alone reads, in Arabic, as "at no time" rather than "does not repeat".
                Text(String(localized: "repeat.never", defaultValue: "Never")).tag(Recurrence?.none)
                ForEach(Recurrence.allCases, id: \.self) { rule in
                    Text(rule.displayName).tag(Recurrence?.some(rule))
                }
            }
            TextField("Memo", text: $draft.memo, axis: .vertical)
                .focused($focusedField, equals: .memo)
            clearedRow
        } footer: {
            if let note = draft.repeatNote {
                Text(note)
            }
        }
    }

    /// Cleared is a yes or a no, so it is a switch.
    ///
    /// Reconciled is the third state and not one to set by hand: it means checked against a
    /// statement, which the reconcile flow does. It shows as a locked row rather than disappearing,
    /// because an entry that says it was reconciled should keep saying so.
    @ViewBuilder
    private var clearedRow: some View {
        if draft.cleared == .reconciled {
            LabeledContent {
                Label("Reconciled", systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            } label: {
                Text("Cleared")
            }
        } else {
            Toggle("Cleared", isOn: $draft.isCleared)
                .tint(Flame.ember)
                .accessibilityIdentifier("cleared-toggle")
        }
    }

    // MARK: - Derived

    /// Worked out when the name or the focus changes, not in `body`: the whole form re-renders on
    /// every keystroke in any of its fields, and each render fetched every payee.
    private func updatePayeeSuggestions() {
        payeeSuggestions = focusedField == .payee
            ? PayeeMemory.suggestions(matching: draft.payeeName, among: payees)
            : []
    }

    private var openAccounts: [Account] { accounts.filter { !$0.closed } }

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
        if existing != nil { isKeypadShowing = false }
    }

    private func save() {
        guard let account = draft.save(payees: payees, budget: budget, in: modelContext) else { return }
        lastAccountIdentifier = account.identifier.uuidString
        dismiss()
    }

    private func deleteTransaction() {
        guard !draft.hasDeleted else { return }
        draft.delete(budget: budget, in: modelContext)
        dismiss()
    }
}

/// A calculator-style keypad. Digits are minor units, so 1, 2, 3, 4 reads as 12.34.
private struct Keypad: View {
    let onDigit: (Character) -> Void
    let onDelete: () -> Void
    let onClear: () -> Void
    let onDone: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()
                // Its own key: the register's "Clear" marks an entry cleared; this one empties the amount.
                Button(String(localized: "keypad.clear", defaultValue: "Clear"), action: onClear)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(1...9, id: \.self) { number in
                    key("\(number)") { onDigit(Character("\(number)")) }
                }
                iconKey("delete.backward", isAccent: false, action: onDelete)
                key("0") { onDigit("0") }
                iconKey("checkmark", isAccent: true, action: onDone)
                    .accessibilityIdentifier("keypad-done")
                    .accessibilityLabel("Done")
            }
        }
        .padding(.top, 10)
        // A keypad reads 1-2-3 from the left in every language, as the phone's own does.
        .environment(\.layoutDirection, .leftToRight)
    }

    private func key(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 26, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    private func iconKey(_ systemName: String, isAccent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isAccent ? AnyShapeStyle(Flame.gradient) : AnyShapeStyle(.quaternary.opacity(0.35)))
                )
                .foregroundStyle(isAccent ? Color.white : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isAccent ? "keypad-done" : "keypad-delete")
    }
}

/// Picking from a long list is a search, not a scroll.
struct AccountPickerView: View {
    let accounts: [Account]
    let selected: Account?
    let onPick: (Account) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        List {
            let onBudget = matches.filter(\.onBudget)
            let tracking = matches.filter { !$0.onBudget }
            if !onBudget.isEmpty { Section("On budget") { rows(onBudget) } }
            if !tracking.isEmpty { Section("Tracking") { rows(tracking) } }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Account name")
    }

    @ViewBuilder
    private func rows(_ shown: [Account]) -> some View {
        ForEach(shown, id: \.identifier) { account in
            Button {
                onPick(account)
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Text(account.name).foregroundStyle(.primary)
                    CurrencyBadge(code: account.currencyCode)
                    Spacer()
                    if account.identifier == selected?.identifier {
                        Image(systemName: "checkmark").foregroundStyle(Flame.ember)
                    }
                }
            }
            .accessibilityIdentifier("account-option")
        }
    }

    private var matches: [Account] {
        guard !searchText.isEmpty else { return accounts }
        let needle = searchText.lowercased()
        return accounts.filter { $0.name.lowercased().contains(needle) }
    }
}

struct CategoryPickerView: View {
    let categories: [BudgetCategoryModel]
    let selected: BudgetCategoryModel?
    let onPick: (BudgetCategoryModel?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        List {
            Section {
                Button {
                    onPick(nil)
                    dismiss()
                } label: {
                    Text("None").foregroundStyle(.secondary)
                }
            }
            // Grouped once per keystroke. Asked for per group, the search ran once for every group.
            let grouped = groupedMatches
            ForEach(grouped, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.categories, id: \.identifier) { candidate in
                        Button {
                            onPick(candidate)
                            dismiss()
                        } label: {
                            HStack {
                                Text(candidate.displayName).foregroundStyle(.primary)
                                Spacer()
                                if candidate.identifier == selected?.identifier {
                                    Image(systemName: "checkmark").foregroundStyle(Flame.ember)
                                }
                            }
                        }
                        .accessibilityIdentifier("category-option")
                    }
                }
            }
        }
        .navigationTitle("Category")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Category or group")
    }

    private var matches: [BudgetCategoryModel] {
        guard !searchText.isEmpty else { return categories }
        let needle = searchText.lowercased()
        return categories.filter {
            $0.displayName.lowercased().contains(needle)
                || ($0.group?.displayName.lowercased().contains(needle) ?? false)
        }
    }

    /// The matches under their groups' names, in the order the groups first appear.
    private struct MatchedGroup {
        let name: String
        var categories: [BudgetCategoryModel]
    }

    private var groupedMatches: [MatchedGroup] {
        var grouped: [MatchedGroup] = []
        var index: [String: Int] = [:]
        for candidate in matches {
            let name = candidate.group?.displayName ?? ""
            if let at = index[name] {
                grouped[at].categories.append(candidate)
            } else {
                index[name] = grouped.count
                grouped.append(MatchedGroup(name: name, categories: [candidate]))
            }
        }
        return grouped
    }
}

private struct CurrencyPickerView: View {
    let selected: String
    let suggested: [String]
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty, !suggested.isEmpty {
                    Section("Likely") { ForEach(suggested, id: \.self) { row($0) } }
                }
                Section(searchText.isEmpty ? String(localized: "All currencies") : String(localized: "Results")) {
                    ForEach(matches, id: \.self) { row($0) }
                }
            }
            .navigationTitle("Currency")
            .searchable(text: $searchText, prompt: "Code or name")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .flameTinted()
    }

    private func row(_ code: String) -> some View {
        Button {
            onPick(code)
            dismiss()
        } label: {
            HStack {
                Text(code).fontWeight(.medium)
                if let name = CurrencyRegistry.currency(forCode: code).localizedName {
                    Text(name).foregroundStyle(.secondary)
                }
                Spacer()
                if code == selected { Image(systemName: "checkmark").foregroundStyle(Flame.ember) }
            }
        }
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
