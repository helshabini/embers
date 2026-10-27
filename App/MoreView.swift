import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

struct MoreView: View {
    @Environment(BudgetModel.self) private var budget
    @Environment(CloudSync.self) private var cloud
    @Query private var accounts: [Account]
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some View {
        List {
            Section("Your data") {
                NavigationLink {
                    ImportView()
                } label: {
                    Label("Import from YNAB", systemImage: "square.and.arrow.down")
                }
                NavigationLink {
                    BackupView()
                } label: {
                    Label("Backups & Start Fresh", systemImage: "externaldrive")
                }
            }


            Section("Currency") {
                NavigationLink {
                    FXSettingsView()
                } label: {
                    LabeledContent("Currency & FX", value: budget.baseCurrency.code)
                }
                if !foreignCurrencies.isEmpty {
                    LabeledContent(
                        "Account currencies",
                        value: foreignCurrencies.sorted().joined(separator: ", ")
                    )
                }
            }

            Section {
                NavigationLink {
                    BudgetCheckView()
                } label: {
                    LabeledContent {
                        if budget.findings.isClear {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(Flame.inflow)
                        } else {
                            Text("\(budget.findings.uncategorisedBoundaryTransfers.count)")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Flame.outflow, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    } label: {
                        Label("Check your budget", systemImage: "stethoscope")
                    }
                }
                .accessibilityIdentifier("budget-check")
            } footer: {
                Text("Finds anything the plan cannot settle on its own.")
            }

            Section("Appearance") {
                Picker(selection: $appearance) {
                    ForEach(Appearance.allCases) { option in
                        Label(option.name, systemImage: option.symbol).tag(option)
                    }
                } label: {
                    Label("Theme", systemImage: "circle.lefthalf.filled")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("appearance-picker")
            }

            Section {
                // iOS keeps the choice, in Settings → Embers → Language, and offers it to any app
                // with more than one language. Following the phone is its default.
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    LabeledContent {
                        Text(currentLanguage)
                    } label: {
                        Label("Language", systemImage: "globe")
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("language-settings")
            } footer: {
                Text("Opens Settings, where Embers can follow your iPhone's language or use its own.")
            }

            // Below the language row: above it, a long language pushed that row out of a test's reach.
            Section {
                NavigationLink {
                    ReminderSettingsView()
                } label: {
                    Label("Reminders", systemImage: "bell")
                }
                .accessibilityIdentifier("reminder-settings")
            }

            Section {
                SyncStatusView(isDetailed: true)
            } header: {
                Text("Where your data lives")
            } footer: {
                if cloud.status == .syncing {
                    Text(
                        "Your budget is kept in iCloud and is the same on every iPhone, iPad and Mac signed in with your Apple Account. Save a backup to iCloud Drive for a copy you can go back to."
                    )
                } else {
                    Text(
                        "Your budget is kept on this device and is included in iPhone backups, so restoring a new phone brings it with you. Save a backup to iCloud Drive for a copy you can restore any time."
                    )
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 2) {
                Text("Embers")
                    .font(.footnote.weight(.medium))
                Text("Your sure way to FIRE")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            // The list scrolls under the inset, so it needs something to scroll under. A material
            // rather than a colour, so it stays right in either scheme.
            .background(.bar)
        }
        .navigationTitle("More")
    }

    /// The language the app is showing, in that language: "English", "العربية".
    private var currentLanguage: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: code).localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }

    /// Account currencies other than the plan's: the ones that attract a bank FX fee on entry.
    private var foreignCurrencies: Set<String> {
        Set(accounts.map(\.currencyCode)).subtracting([budget.baseCurrency.code])
    }
}
