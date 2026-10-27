import EmbersCore
import SwiftUI

/// Which reminders come to this device.
///
/// Each is a switch of its own, because each is useful to someone and noise to someone else, and
/// the choice stays on this device: the iPad need not say everything the phone does.
struct ReminderSettingsView: View {
    @State private var reminders = ReminderScheduler.shared
    @AppStorage(ReminderSettings.cardPaymentDayKey) private var cardPaymentDay = 25

    var body: some View {
        Form {
            Section {
                switch reminders.authorization {
                case .authorized, .provisional, .ephemeral:
                    Label("Reminders are on", systemImage: "bell.badge")
                case .denied:
                    Button {
                        SystemSettings.openNotifications()
                    } label: {
                        Label("Allow Notifications in Settings", systemImage: "bell.slash")
                    }
                default:
                    Button {
                        Task { await reminders.requestPermission() }
                    } label: {
                        Label("Turn On Reminders", systemImage: "bell")
                    }
                    .accessibilityIdentifier("turn-on-reminders")
                }
            } footer: {
                Text("Reminders are worked out on this device from your plan, and come whether or not Embers is open.")
            }

            Section("Payments") {
                toggle(.due, "Scheduled payment due", "The morning it is due, with Approve and Skip.")
                toggle(.shortfall, "Category short for a payment", "Three days ahead, when what it holds will not cover it.")
                toggle(.cardPayment, "Credit card payment", "Three days before the payment day, when a card owes something.")
                Stepper(value: $cardPaymentDay, in: 1...31) {
                    LabeledContent("Card payment day", value: cardPaymentDay.formatted(.number.locale(.display)))
                }
                .onChange(of: cardPaymentDay) { _, _ in reminders.replan() }
            }

            Section("Habits") {
                toggle(.monthEnd, "Last day of the month", "In the evening: reconcile and look over the plan.")
                toggle(.monthStart, "New month", "On the 1st: give the month's money a job.")
                toggle(.quiet, "A few quiet days", "When nothing has been entered for three days.")
                toggle(.reconcile, "Accounts to reconcile", "Only for accounts with entries over a month old that no statement has checked. Again a week later if still so.")
                toggle(.backup, "Backup", "When no backup has been saved on this device for a month.")
            }
        }
        .navigationTitle("Reminders")
        .inlineNavigationTitle()
        .task { await reminders.readAuthorization() }
        .disabled(!ReminderScheduler.isEnabled)
    }

    private func toggle(_ kind: ReminderKind, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        ReminderToggle(kind: kind, title: title, detail: detail)
    }
}

private struct ReminderToggle: View {
    let kind: ReminderKind
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @AppStorage private var isOn: Bool

    init(kind: ReminderKind, title: LocalizedStringKey, detail: LocalizedStringKey) {
        self.kind = kind
        self.title = title
        self.detail = detail
        _isOn = AppStorage(wrappedValue: true, ReminderSettings.key(kind))
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: isOn) { _, _ in ReminderScheduler.shared.replan() }
    }
}
