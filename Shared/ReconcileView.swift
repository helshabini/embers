import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// Checking an account against its statement.
///
/// Two steps, in the order a statement is actually read: say what the bank says, then confirm. The
/// difference is shown before anything is written, because an adjustment is a real transaction and
/// nobody should find one they did not expect.
struct ReconcileView: View {
    let account: Account

    @Environment(\.modelContext) private var modelContext
    @Environment(BudgetModel.self) private var budget
    @Environment(\.dismiss) private var dismiss

    @State private var statementText = ""
    @State private var isConfirming = false
    @State private var quote: ExchangeRateQuote?
    /// Read once, as the screen opens. Fetching it in `body` re-read the account's every row on
    /// each keystroke — five times over, once per place the figures appear — and typing lagged.
    @State private var cleared: ReconcileWriter.Plan?
    /// `nil` until chosen: then the account's own currency whenever there is a rate for it.
    @State private var chosenCurrencyCode: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Cleared balance") {
                        // Blank for the moment before it is read, rather than a $0.00 that is wrong.
                        if cleared != nil {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(budget.money(MinorUnits(clearedBalance)))
                                    .foregroundStyle(Flame.amountColor(MinorUnits(clearedBalance)))
                                if let clearedInAccountCurrency {
                                    Text("≈ \(clearedInAccountCurrency)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    Text(
                        "What the app believes has reached the bank. Anything still uncleared is left out, because the statement has not seen it either."
                    )
                }

                Section {
                    if isForeign {
                        Picker("Count in", selection: currencyChoice) {
                            Text(account.currency.code).tag(account.currency.code)
                            Text(budget.baseCurrency.code).tag(budget.baseCurrency.code)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("statement-currency")
                    }
                    LabeledContent(account.type.isLiability ? String(localized: "Statement says owed") : String(localized: "Statement says")) {
                        TextField("0.00", text: $statementText)
                            // Its row is labelled already; on the Mac a field's title would show beside it too.
                            .labelsHidden()
                            .numbersKeyboard()
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("statement-balance")
                    }
                    if isCountedInAccountCurrency, let statementInBase {
                        LabeledContent(String(localized: "In \(budget.baseCurrency.code)")) {
                            Text(budget.money(MinorUnits(statementInBase)))
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text(RateAttribution.note(
                        statementFooter,
                        crediting: isCountedInAccountCurrency && hasRate ? quote?.providerName : nil
                    ))
                }

                if let plan {
                    Section {
                        LabeledContent("Difference") {
                            Text(budget.money(MinorUnits(plan.differenceMinor)))
                                .foregroundStyle(Flame.amountColor(MinorUnits(plan.differenceMinor)))
                                .accessibilityIdentifier("reconcile-difference")
                        }
                    } footer: {
                        Text(explanation(of: plan))
                    }

                    Section {
                        Button {
                            if plan.needsAdjustment { isConfirming = true } else { reconcile() }
                        } label: {
                            Label(
                                plan.needsAdjustment ? String(localized: "Adjust and Reconcile") : String(localized: "Reconcile"),
                                systemImage: "checkmark.seal"
                            )
                        }
                        .accessibilityIdentifier("reconcile-confirm")
                    }
                }
            }
            .navigationTitle("Reconcile")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Write an adjustment?", isPresented: $isConfirming) {
                Button("Cancel", role: .cancel) {}
                Button("Adjust") { reconcile() }
            } message: {
                Text(
                    plan.map {
                        String(localized: "A transaction for \(budget.money(MinorUnits($0.differenceMinor))) will be added so this account matches the statement.")
                    } ?? ""
                )
            }
        }
        .flameTinted()
        .task {
            cleared = try? ReconcileWriter.plan(for: account, statementBalanceMinor: 0, in: modelContext)
            guard isForeign else { return }
            // The cached rate first, so the screen works at once and offline; then a fresher one
            // if the cache is stale. Nothing here may wait on the network before showing.
            quote = try? ExchangeRateService.latestQuote(in: modelContext, baseCode: budget.baseCurrency.code)
            if let fresher = await ExchangeRateService.refreshIfNeeded(
                baseCode: budget.baseCurrency.code, in: modelContext
            ) {
                quote = fresher
            }
        }
        // Once a figure is typed its currency is settled: a rate arriving afterwards must not
        // reinterpret 5,000 typed as dollars into 5,000 pounds.
        .onChange(of: statementText) { _, _ in
            if chosenCurrencyCode == nil { chosenCurrencyCode = currencyChoice.wrappedValue }
        }
    }

    private var clearedBalance: Int { cleared?.clearedBalanceMinor ?? 0 }

    private var isForeign: Bool { account.currency.code != budget.baseCurrency.code }

    /// The account's currency has to be convertible to be offered as the default: with no rate yet
    /// — a first launch offline — the field would take a figure and never show a difference.
    private var hasRate: Bool {
        quote?.rate(from: account.currency.code, to: budget.baseCurrency.code) != nil
    }

    private var currencyChoice: Binding<String> {
        Binding(
            get: { chosenCurrencyCode ?? (hasRate ? account.currency.code : budget.baseCurrency.code) },
            set: { chosenCurrencyCode = $0 }
        )
    }

    private var isCountedInAccountCurrency: Bool {
        isForeign && currencyChoice.wrappedValue == account.currency.code
    }

    private var statementCurrency: Currency {
        isCountedInAccountCurrency ? account.currency : budget.baseCurrency
    }

    /// What was typed, in the plan's currency. `nil` until a figure is typed, or when it is in the
    /// account's currency and there is no rate to convert it with.
    private var statementInBase: Int? {
        guard let typed = Money.parse(statementText, currency: statementCurrency) else { return nil }
        let signed = account.type.isLiability ? -abs(typed.minorUnits) : typed.minorUnits
        guard isCountedInAccountCurrency else { return Int(signed) }
        guard let quote else { return nil }
        return CurrencyConverter(baseCurrency: budget.baseCurrency)
            .value(of: signed, in: account.currency, quote: quote)
            .map(Int.init)
    }

    /// The cleared balance as the account would count it, so a wallet can be checked at a glance.
    private var clearedInAccountCurrency: String? {
        guard isForeign, let quote else { return nil }
        let value = CurrencyConverter(baseCurrency: account.currency)
            .value(of: MinorUnits(clearedBalance), in: budget.baseCurrency, quote: quote)
        return value.map { Money(minorUnits: $0, currency: account.currency).formatted() }
    }

    private var statementFooter: String {
        let closing = account.type.isLiability
            ? String(localized: "The closing balance on the statement, as a positive number.")
            : String(localized: "The closing balance on the statement.")
        guard isCountedInAccountCurrency else { return closing }
        guard hasRate else {
            return String(localized: "There is no exchange rate for \(account.currency.code) yet, so this cannot be converted. Count in \(budget.baseCurrency.code) instead.")
        }
        // The cleared balance was converted entry by entry, at each day's rate. Today's rate values
        // it differently, so part of any difference is the rate having moved — and saying so stops
        // that looking like money gone missing.
        return closing + " " + String(localized: "Converted at the latest rate, with no fee. Rates move, so a small difference can be the rate rather than the money.")
    }

    /// `nil` until a statement balance has actually been typed: there is nothing to compare to yet.
    private var plan: ReconcileWriter.Plan? {
        guard let statement = statementInBase else { return nil }
        return cleared?.comparing(to: statement)
    }

    private func explanation(of plan: ReconcileWriter.Plan) -> String {
        guard plan.needsAdjustment else {
            return String(localized: "The statement agrees. Reconciling will lock \(plan.rowsToLock) entries as checked.", locale: .display)
        }
        // Whole sentences for each case: "more" and "less" spliced into one sentence cannot be
        // translated, since other languages do not put them in the same place.
        let difference = budget.money(MinorUnits(abs(plan.differenceMinor)))
        switch (plan.differenceMinor > 0, account.onBudget) {
        case (true, true):
            return String(localized: "The bank holds \(difference) more than the app thinks. Reconciling writes one adjustment for the difference against Ready to Assign.")
        case (true, false):
            return String(localized: "The bank holds \(difference) more than the app thinks. Reconciling writes one adjustment for the difference.")
        case (false, true):
            return String(localized: "The bank holds \(difference) less than the app thinks. Reconciling writes one adjustment for the difference against Ready to Assign.")
        case (false, false):
            return String(localized: "The bank holds \(difference) less than the app thinks. Reconciling writes one adjustment for the difference.")
        }
    }

    private func reconcile() {
        guard let statement = statementInBase else { return }
        try? ReconcileWriter.reconcile(account, statementBalanceMinor: statement, in: modelContext)
        budget.refresh(in: modelContext)
        dismiss()
    }
}
