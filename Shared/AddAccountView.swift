import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// Adds an account, with the opening balance that makes it worth adding.
///
/// The type drives everything else: whether it belongs on the budget, whether an opening balance is
/// money you have or money you owe, and whether a payment category has to exist alongside it. So the
/// type is chosen first and the rest of the form follows from it.
struct AddAccountView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(BudgetModel.self) private var budget
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: AccountType = .checking
    @State private var currencyCode = ""
    @State private var balanceText = ""
    @State private var onBudget: Bool?
    @State private var isChoosingCurrency = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("account-name")
                    Picker("Type", selection: $type) {
                        ForEach(AccountType.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .accessibilityIdentifier("account-type")
                } footer: {
                    Text(
                        type.belongsOnBudgetByDefault
                            ? String(localized: "Money here is budgeted: it counts towards Ready to Assign.")
                            : String(localized: "A tracking account counts towards net worth only. Nothing here is budgeted.")
                    )
                }

                Section {
                    NavigationLink {
                        CurrencyListView(selected: effectiveCurrency) { currencyCode = $0 }
                    } label: {
                        LabeledContent("Held in", value: effectiveCurrency)
                    }
                    .accessibilityIdentifier("account-currency")
                } footer: {
                    Text(
                        "Paying in \(effectiveCurrency) from this account is a domestic charge. Anything else attracts the bank's FX fee."
                    )
                }

                Section {
                    LabeledContent(balanceLabel) {
                        TextField("0.00", text: $balanceText)
                            // Its row is labelled already; on the Mac a field's title would show beside it too.
                            .labelsHidden()
                            .decimalKeyboard()
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("account-balance")
                    }
                } header: {
                    Text("Today's balance")
                } footer: {
                    Text(balanceFooter)
                }

                Section {
                    Toggle("On budget", isOn: onBudgetBinding)
                } footer: {
                    Text("Changes what the type would do by default. Most accounts want the default.")
                }
            }
            .navigationTitle("New Account")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add).disabled(!canAdd)
                }
            }
        }
        .flameTinted()
    }

    /// The plan's currency until one is chosen: most accounts hold the currency the plan is in.
    private var effectiveCurrency: String {
        currencyCode.isEmpty ? budget.baseCurrency.code : currencyCode
    }

    /// A liability's balance is entered as what is owed, so nobody has to type a minus sign.
    private var balanceLabel: String { type.isLiability ? String(localized: "Owed now") : String(localized: "Balance") }

    private var balanceFooter: String {
        if type.isLiability {
            return String(localized: "What you owe today, as a positive number. Leave it empty if nothing is owed.")
        }
        return String(localized: "What the account holds today, in \(budget.baseCurrency.code). Leave it empty for zero.")
    }

    private var onBudgetBinding: Binding<Bool> {
        Binding(
            get: { onBudget ?? type.belongsOnBudgetByDefault },
            set: { onBudget = $0 }
        )
    }

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The typed balance as signed minor units: owing money is a negative balance.
    ///
    /// A liability is entered as what is owed, so the sign is supplied here rather than typed — but a
    /// minus sign typed anyway is honoured rather than flipped back.
    private var startingBalanceMinor: Int {
        guard let money = Money.parse(balanceText, currency: budget.baseCurrency) else { return 0 }
        let owes = type.isLiability || money.isNegative
        return Int(owes ? -abs(money.minorUnits) : abs(money.minorUnits))
    }

    private func add() {
        try? AccountWriter.create(
            name: name,
            type: type,
            currencyCode: effectiveCurrency,
            onBudget: onBudget,
            startingBalanceMinor: startingBalanceMinor,
            in: modelContext
        )
        budget.syncCreditCardCategories(in: modelContext)
        budget.refresh(in: modelContext)
        dismiss()
    }
}
