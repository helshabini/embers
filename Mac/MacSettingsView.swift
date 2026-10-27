import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// The phone's More screen, as a Mac's Settings window (⌘,).
///
/// The screens are the phone's own, shared: each is a form either way. Check your budget is not
/// here — it is a place in the sidebar, shown when it has something to say.
struct MacSettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Currency & FX", systemImage: "dollarsign.arrow.circlepath") {
                NavigationStack { FXSettingsView() }
            }
            Tab("Reminders", systemImage: "bell") {
                NavigationStack { ReminderSettingsView() }
            }
            Tab("Import", systemImage: "square.and.arrow.down") {
                NavigationStack { ImportView() }
            }
            Tab("Backups", systemImage: "externaldrive") {
                NavigationStack { BackupView() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
        .flameTinted()
    }
}

private struct GeneralSettings: View {
    @Environment(CloudSync.self) private var cloud
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some View {
        Form {
            Picker(selection: $appearance) {
                ForEach(Appearance.allCases) { option in
                    Label(option.name, systemImage: option.symbol).tag(option)
                }
            } label: {
                Label("Theme", systemImage: "circle.lefthalf.filled")
            }
            .accessibilityIdentifier("appearance-picker")

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
                    Text("Your budget is kept on this Mac. Save a backup for a copy you can restore any time.")
                }
            }

            Section {
                LabeledContent("Language") {
                    // macOS keeps a language for each app in System Settings, as iOS does.
                    Text(currentLanguage)
                }
            } footer: {
                Text("Choose a language for Embers in System Settings → General → Language & Region → Applications.")
            }
        }
    }

    /// The language the app is showing, in that language: "English", "العربية".
    private var currentLanguage: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: code).localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }
}
