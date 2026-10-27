import EmbersCore
import EmbersData
import Observation
import SwiftData
import SwiftUI
import UserNotifications

/// Hands reminders to the system, and answers what comes back from them.
///
/// The app has no server, and needs none: every reminder is about a date the plan already knows,
/// so it is scheduled ahead as a local notification and iOS delivers it whether or not the app is
/// open. They are planned again after every recompute — and the recompute runs after every edit,
/// after iCloud brings in another device's changes, and when the app comes forward — so what is
/// waiting always matches the plan as it was last seen.
@MainActor
@Observable
final class ReminderScheduler: NSObject {
    static let shared = ReminderScheduler()

    /// Off for UI tests: iOS's permission alert would sit over whichever screen a test is driving.
    static let isEnabled = !ProcessInfo.processInfo.arguments.contains("-no-reminders")

    /// The tab a tapped reminder asks for. Taken and cleared by `BudgetLifecycle`'s owner.
    var route: AppTab?
    /// Bumped when a reminder's button has changed the store, so the figures are worked out again.
    private(set) var changes = 0
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private var lastFacts: ReminderFacts?
    @ObservationIgnored private var lastPlanned: [Reminder]?
    private let center = UNUserNotificationCenter.current()

    private static let ledgerKey = "reminders.ledger"
    nonisolated private static let sinceKey = "reminders.since"
    nonisolated static let lastBackupKey = "reminders.lastBackupAt"

    /// When a backup was last saved here, or when reminders began if never — so a new install is
    /// not asked for a backup on its first morning.
    nonisolated static var lastBackupAt: Date? {
        let defaults = UserDefaults.standard
        if let saved = defaults.object(forKey: lastBackupKey) as? Date { return saved }
        if defaults.object(forKey: sinceKey) == nil { defaults.set(Date(), forKey: sinceKey) }
        return defaults.object(forKey: sinceKey) as? Date
    }

    static func backupSaved() {
        UserDefaults.standard.set(Date(), forKey: lastBackupKey)
    }

    private enum Action {
        static let category = "due"
        static let approve = "approve"
        static let skip = "skip"
    }

    /// Set as the centre's delegate before launch finishes, or a button pressed while the app was
    /// closed is never delivered.
    func attach() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Action.category,
                actions: [
                    // Money moves on these, so not from a locked phone.
                    UNNotificationAction(identifier: Action.approve, title: String(localized: "Approve"), options: [.authenticationRequired]),
                    UNNotificationAction(identifier: Action.skip, title: String(localized: "Skip This One"), options: [.authenticationRequired, .destructive]),
                ],
                intentIdentifiers: []
            ),
        ])
        Task { await readAuthorization() }
    }

    func readAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Asks once, at a moment the question makes sense — a first repeat — rather than at launch,
    /// when nobody yet knows what the app would remind them of.
    func askIfUndecided() {
        guard Self.isEnabled else { return }
        Task {
            await readAuthorization()
            guard authorization == .notDetermined else { return }
            await requestPermission()
        }
    }

    func requestPermission() async {
        guard Self.isEnabled else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await readAuthorization()
        lastPlanned = nil
        if let lastFacts { replan(lastFacts) }
    }

    /// Plans again from the last facts: the clock has moved, or a preference has.
    func replan() {
        lastPlanned = nil
        if let lastFacts { replan(lastFacts) }
    }

    func replan(_ facts: ReminderFacts) {
        lastFacts = facts
        guard Self.isEnabled else { return }
        Task { await schedule(facts) }
    }

    private func schedule(_ facts: ReminderFacts) async {
        await readAuthorization()
        guard authorization == .authorized || authorization == .provisional else { return }

        var ledger = Self.loadLedger()
        ledger.settle(now: Date())
        let planned = ReminderPlanner(preferences: ReminderSettings.preferences).plan(facts, ledger: ledger)
        try? await center.setBadgeCount(facts.needsAttention)

        // Every recompute plans; only a different answer touches what iOS holds.
        guard planned != lastPlanned else { return }
        lastPlanned = planned
        center.removeAllPendingNotificationRequests()
        for reminder in planned {
            try? await center.add(request(for: reminder))
        }
        ledger.record(planned)
        Self.save(ledger)
    }

    private func request(for reminder: Reminder) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.userInfo = ["kind": reminder.kind.rawValue]
        if let badge = reminder.badge { content.badge = NSNumber(value: badge) }
        if let transactionID = reminder.transactionID {
            content.categoryIdentifier = Action.category
            content.userInfo["transaction"] = transactionID.uuidString
        }
        // Calendar parts without a time zone: nine o'clock wherever the phone is when it comes.
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireDate)
        return UNNotificationRequest(
            identifier: reminder.id,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        )
    }

    private static func loadLedger() -> ReminderLedger {
        guard let data = UserDefaults.standard.data(forKey: ledgerKey),
              let ledger = try? JSONDecoder().decode(ReminderLedger.self, from: data)
        else { return ReminderLedger() }
        return ledger
    }

    private static func save(_ ledger: ReminderLedger) {
        UserDefaults.standard.set(try? JSONEncoder().encode(ledger), forKey: ledgerKey)
    }

    // MARK: - Answering

    /// Approves or skips from the notification itself, through the same writers the approval list
    /// uses — so two devices approving the same payment are folded together as they are there.
    ///
    /// The button may have woken a closed app with no window, so the store is opened here if the
    /// scene has not already.
    fileprivate func answer(_ action: String, transactionID: UUID) {
        StoreLoader.shared.load()
        guard case let .ready(container) = StoreLoader.shared.state else { return }
        let context = container.mainContext
        let found = try? context.fetch(
            FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.identifier == transactionID })
        ).first
        // Answered already, here or on another device, or deleted since: nothing to do.
        guard let transaction = found, transaction.isLive, transaction.awaitsApproval else { return }
        switch action {
        case Action.approve: try? RecurrenceWriter.approve(transaction, in: context)
        case Action.skip: try? RecurrenceWriter.skip(transaction, in: context)
        default: return
        }
        changes &+= 1
    }

    fileprivate func open(_ kind: ReminderKind?) {
        switch kind {
        case .due, .quiet: route = .transactions
        case .shortfall, .cardPayment, .monthStart: route = .plan
        case .monthEnd, .reconcile: route = .accounts
        case .backup, nil: route = .home
        }
    }
}

extension ReminderScheduler: UNUserNotificationCenterDelegate {
    /// Shown while the app is open too: a payment due today is worth a banner either way.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let kind = (info["kind"] as? String).flatMap(ReminderKind.init(rawValue:))
        let transactionID = (info["transaction"] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        await MainActor.run {
            if let transactionID, action != UNNotificationDefaultActionIdentifier,
               action != UNNotificationDismissActionIdentifier {
                answer(action, transactionID: transactionID)
            } else {
                open(kind)
            }
        }
    }
}

/// What the person has chosen for reminders on this device.
///
/// In `UserDefaults`, not the store: the store syncs, and a choice like "not on the iPad" has to
/// stay on the iPad.
enum ReminderSettings {
    static func key(_ kind: ReminderKind) -> String { "reminders.\(kind.rawValue)" }
    static let cardPaymentDayKey = "reminders.cardPaymentDay"

    static var preferences: ReminderPreferences {
        let defaults = UserDefaults.standard
        let day = defaults.integer(forKey: cardPaymentDayKey)
        return ReminderPreferences(
            enabled: Set(ReminderKind.allCases.filter { defaults.object(forKey: key($0)) as? Bool ?? true }),
            cardPaymentDay: day == 0 ? 25 : day
        )
    }
}

/// The tabs, so a reminder can say which one it is about.
enum AppTab: Hashable {
    case home, plan, transactions, accounts, reports
}
