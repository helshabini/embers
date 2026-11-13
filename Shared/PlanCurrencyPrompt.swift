import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// Asks a new plan which currency it is kept in, once, before anything is recorded in it.
///
/// Every amount is stored in this currency, so it is fixed by the first one
/// (`PlanSettingsWriter`). Shown when a plan holding no amounts opens for the first time on this
/// device, and again after Start Fresh.
struct PlanCurrencyPrompt: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(BudgetModel.self) private var budget
    @Environment(\.dismiss) private var dismiss

    @State private var code: String
    @State private var failure: String?

    init(suggested: String) {
        _code = State(initialValue: suggested)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        CurrencyListView(selected: code) { code = $0 }
                    } label: {
                        LabeledContent("Plan currency") {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(code)
                                if let name = CurrencyRegistry.localizedName(forCode: code) {
                                    Text(name).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("plan-currency")
                } footer: {
                    Text(
                        "Balances, assignments and targets are all kept in this currency. Each account can still be held in its own, and anything you pay in another currency is converted. It can be changed until the first amount is recorded."
                    )
                }

                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Choose Your Currency")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue", action: choose)
                        .accessibilityIdentifier("plan-currency-continue")
                }
            }
        }
        // There is no right answer to skip to: closing it without one would leave the plan in a
        // currency nobody chose.
        .interactiveDismissDisabled()
        #if os(macOS)
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 320)
        #endif
    }

    private func choose() {
        do {
            try PlanSettingsWriter.setBaseCurrency(code, in: modelContext)
            budget.planCurrencyChosen()
            budget.refresh(in: modelContext)
            dismiss()
        } catch PlanSettingsWriter.Refusal.planHoldsFigures {
            // Another device recorded an amount while this was open, so the plan's currency is
            // already settled; holding the sheet up would leave nothing to do but stare at it.
            budget.planCurrencyChosen()
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
