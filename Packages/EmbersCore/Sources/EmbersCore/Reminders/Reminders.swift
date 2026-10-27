import Foundation

/// Each thing the app can remind the person of, switched on or off on its own.
///
/// There is no server. Every reminder is a local notification the app schedules for itself, with
/// a date it already knows — a scheduled payment's day, the end of a month — and re-plans whenever
/// it runs. iOS delivers them whether or not the app is open.
public enum ReminderKind: String, CaseIterable, Codable, Sendable {
    /// A scheduled entry's day has come and it waits to be approved.
    case due
    /// A scheduled payment is coming and its category does not hold enough for it.
    case shortfall
    /// Credit cards owe something and the payment day is close.
    case cardPayment
    /// The last day of the month: reconcile and look over the plan.
    case monthEnd
    /// The first of the month: give the new month's money a job.
    case monthStart
    /// Nothing entered for a few days.
    case quiet
    /// An account holds entries over a month old that no statement has checked.
    case reconcile
    /// No backup saved on this device for a month.
    case backup

    /// Sent again a week later while the condition stands. The rest fire once.
    public var nags: Bool { self == .reconcile || self == .backup }
}

/// What the plan knows that a reminder could be about, read once per recompute.
public struct ReminderFacts: Sendable, Equatable {
    /// An entry awaiting approval, dated after today. A transfer appears once.
    public struct Scheduled: Sendable, Equatable {
        public var transactionID: UUID
        /// A budget day: midday UTC.
        public var date: Date
        /// The payee, or where a transfer goes.
        public var name: String
        /// Signed, in the plan's currency.
        public var amount: MinorUnits

        public init(transactionID: UUID, date: Date, name: String, amount: MinorUnits) {
            self.transactionID = transactionID
            self.date = date
            self.name = name
            self.amount = amount
        }
    }

    /// A category holding less than what is scheduled out of it later this month.
    public struct Shortfall: Sendable, Equatable {
        public var categoryID: UUID
        public var category: String
        public var needed: MinorUnits
        /// The first scheduled payment out of it: a budget day.
        public var firstDue: Date

        public init(categoryID: UUID, category: String, needed: MinorUnits, firstDue: Date) {
            self.categoryID = categoryID
            self.category = category
            self.needed = needed
            self.firstDue = firstDue
        }
    }

    /// An open account with entries no statement has checked yet.
    ///
    /// Only accounts with such entries are listed. One that has seen nothing since it was last
    /// reconciled has nothing to check, so it is never nagged about however long ago that was.
    public struct Unreconciled: Sendable, Equatable {
        public var accountID: UUID
        public var account: String
        /// The oldest entry not yet reconciled: a budget day.
        public var oldest: Date

        public init(accountID: UUID, account: String, oldest: Date) {
            self.accountID = accountID
            self.account = account
            self.oldest = oldest
        }
    }

    public var currency: Currency
    /// Whether there is anything to remind about at all: a store with no accounts has no plan yet.
    public var holdsAPlan: Bool
    /// What the badge shows now: entries due for approval and entries with no category.
    public var needsAttention: Int
    public var scheduled: [Scheduled]
    public var shortfalls: [Shortfall]
    /// Open credit cards owing money.
    public var cardsOwing: [String]
    public var unreconciled: [Unreconciled]
    /// When anything was last entered: an instant.
    public var lastEntryAt: Date?
    /// When a backup was last saved on this device, or when reminders began if never.
    public var lastBackupAt: Date?

    public init(
        currency: Currency,
        holdsAPlan: Bool = true,
        needsAttention: Int = 0,
        scheduled: [Scheduled] = [],
        shortfalls: [Shortfall] = [],
        cardsOwing: [String] = [],
        unreconciled: [Unreconciled] = [],
        lastEntryAt: Date? = nil,
        lastBackupAt: Date? = nil
    ) {
        self.currency = currency
        self.holdsAPlan = holdsAPlan
        self.needsAttention = needsAttention
        self.scheduled = scheduled
        self.shortfalls = shortfalls
        self.cardsOwing = cardsOwing
        self.unreconciled = unreconciled
        self.lastEntryAt = lastEntryAt
        self.lastBackupAt = lastBackupAt
    }
}

/// What the person has chosen on this device. Kept per device, not synced: an iPad that also
/// reminded about every payment would say everything twice.
public struct ReminderPreferences: Sendable, Equatable {
    public var enabled: Set<ReminderKind>
    /// When the morning reminders come: payments due, the new month, cards, nudges.
    public var morningHour: Int
    /// When the evening ones come: the month's last day, and a quiet few days.
    public var eveningHour: Int
    /// The day of the month card payments fall due. The 25th is the common case; a month shorter
    /// than the day uses its last.
    public var cardPaymentDay: Int

    /// Early enough that a bank transfer made that morning lands in time, with a weekend between.
    public static let cardLeadDays = 3
    /// How far ahead of a short category's payment it is mentioned: time to move money first.
    public static let shortfallLeadDays = 3
    public static let quietAfterDays = 3
    public static let reconcileAfterDays = 30
    public static let backupAfterDays = 30
    public static let nagEveryDays = 7
    /// iOS keeps 64 pending per app. Planned as far as this, and no more than `limit`.
    public static let horizonDays = 35
    public static let limit = 60

    public init(
        enabled: Set<ReminderKind> = Set(ReminderKind.allCases),
        morningHour: Int = 9,
        eveningHour: Int = 19,
        cardPaymentDay: Int = 25
    ) {
        self.enabled = enabled
        self.morningHour = morningHour
        self.eveningHour = eveningHour
        self.cardPaymentDay = cardPaymentDay
    }
}

/// One notification to schedule.
public struct Reminder: Sendable, Equatable {
    /// Stable for the same occasion, so re-planning replaces it rather than adding a second. A
    /// payment's includes its date: skipped to next month, it is a new occasion.
    public var id: String
    public var kind: ReminderKind
    /// The instant, worked out in the local time zone.
    public var fireDate: Date
    public var title: String
    public var body: String
    /// What the app icon should show once it fires; nil leaves it as it is.
    public var badge: Int?
    /// The entry a due reminder is about, for its Approve and Skip buttons.
    public var transactionID: UUID?
}

/// What has been scheduled and what has fired, remembered between plans.
///
/// iOS does not say what it delivered while the app was closed, so anything planned for a moment
/// now past is taken as fired. That is what keeps a one-off from being sent again on the next
/// plan, and a nag a week apart rather than every morning the app is opened.
public struct ReminderLedger: Codable, Sendable, Equatable {
    public var pending: [String: Date] = [:]
    public var delivered: [String: Date] = [:]

    public init() {}

    /// Moves what was due to fire by `now` into what has fired, and forgets old history.
    public mutating func settle(now: Date) {
        for (id, date) in pending where date <= now {
            delivered[id] = date
            pending[id] = nil
        }
        let forgotten = now.addingTimeInterval(-90 * 86_400)
        delivered = delivered.filter { $0.value > forgotten }
    }

    public mutating func record(_ reminders: [Reminder]) {
        pending = Dictionary(reminders.map { ($0.id, $0.fireDate) }, uniquingKeysWith: { first, _ in first })
    }
}

/// Works out every reminder worth scheduling from what the plan knows. No store, no notification
/// centre: given the same facts and the same moment it gives the same answer, so it can be checked.
public struct ReminderPlanner {
    public var preferences: ReminderPreferences
    /// The local calendar: reminders come at local hours, on the local day.
    public var calendar: Calendar
    public var now: Date
    public var locale: Locale

    public init(
        preferences: ReminderPreferences,
        calendar: Calendar = .current,
        now: Date = Date(),
        locale: Locale = .display
    ) {
        self.preferences = preferences
        self.calendar = calendar
        self.now = now
        self.locale = locale
    }

    public func plan(_ facts: ReminderFacts, ledger: ReminderLedger) -> [Reminder] {
        guard facts.holdsAPlan else { return [] }
        let on = preferences.enabled
        var planned: [Reminder] = []
        if on.contains(.due) { planned += due(facts) }
        if on.contains(.shortfall) { planned += shortfalls(facts) }
        if on.contains(.cardPayment) { planned += cardPayment(facts) }
        if on.contains(.monthEnd) { planned += monthEnds() }
        if on.contains(.monthStart) { planned += monthStarts() }
        if on.contains(.quiet), let reminder = quiet(facts) { planned.append(reminder) }
        if on.contains(.reconcile), let reminder = reconcile(facts, ledger: ledger) { planned.append(reminder) }
        if on.contains(.backup), let reminder = backup(facts, ledger: ledger) { planned.append(reminder) }

        let horizon = now.addingTimeInterval(Double(ReminderPreferences.horizonDays) * 86_400)
        return Array(
            planned
                .filter { $0.fireDate > now && $0.fireDate <= horizon }
                // A one-off that has fired stays fired. A nag works out its own next date.
                .filter { $0.kind.nags || ledger.delivered[$0.id] == nil }
                .sorted { $0.fireDate < $1.fireDate }
                .prefix(ReminderPreferences.limit)
        )
    }

    // MARK: - Each kind

    private func due(_ facts: ReminderFacts) -> [Reminder] {
        facts.scheduled.map { entry in
            // The icon shows what will be waiting by then, though the app has not run since.
            let dueByThen = facts.scheduled.filter { $0.date <= entry.date }.count
            let amount = Money(minorUnits: abs(entry.amount), currency: facts.currency).formatted(locale: locale)
            return Reminder(
                id: "due.\(entry.transactionID.uuidString).\(dayKey(entry.date))",
                kind: .due,
                fireDate: at(preferences.morningHour, on: entry.date),
                title: String(localized: "Due today: \(entry.name)", bundle: .module),
                body: String(
                    localized: "\(amount). Approve it once it has gone out, or skip it if it has not.",
                    bundle: .module
                ),
                badge: facts.needsAttention + dueByThen,
                transactionID: entry.transactionID
            )
        }
    }

    private func shortfalls(_ facts: ReminderFacts) -> [Reminder] {
        facts.shortfalls.compactMap { shortfall in
            let paymentMorning = at(preferences.morningHour, on: shortfall.firstDue)
            var fire = at(preferences.morningHour, on: shortfall.firstDue, plusDays: -ReminderPreferences.shortfallLeadDays)
            // Found late, it still comes, as long as there is a morning left before the payment.
            if fire <= now { fire = nextSlot(preferences.morningHour) }
            guard fire < paymentMorning else { return nil }
            let needed = Money(minorUnits: shortfall.needed, currency: facts.currency).formatted(locale: locale)
            return Reminder(
                id: "shortfall.\(shortfall.categoryID.uuidString).\(dayKey(shortfall.firstDue))",
                kind: .shortfall,
                fireDate: fire,
                title: String(localized: "\(shortfall.category) is short", bundle: .module),
                body: String(
                    localized: "\(needed) more is needed for what is due on \(dayName(shortfall.firstDue)). Assign it before then.",
                    bundle: .module
                )
            )
        }
    }

    private func cardPayment(_ facts: ReminderFacts) -> [Reminder] {
        guard !facts.cardsOwing.isEmpty else { return [] }
        let cards = ListFormatter.localizedString(byJoining: facts.cardsOwing)
        return upcomingMonths().compactMap { month in
            let day = min(preferences.cardPaymentDay, daysIn(month))
            let payday = Date.budgetDay(year: month.year, month: month.month, day: day)
            return Reminder(
                id: "card.\(month.description)",
                kind: .cardPayment,
                fireDate: at(preferences.morningHour, on: payday, plusDays: -ReminderPreferences.cardLeadDays),
                title: String(localized: "Card payment due \(dayName(payday))", bundle: .module),
                body: String(
                    localized: "\(cards). Pay now and the transfer has time to arrive.",
                    bundle: .module
                )
            )
        }
    }

    private func monthEnds() -> [Reminder] {
        upcomingMonths().map { month in
            let last = Date.budgetDay(year: month.year, month: month.month, day: daysIn(month))
            return Reminder(
                id: "monthEnd.\(month.description)",
                kind: .monthEnd,
                fireDate: at(preferences.eveningHour, on: last),
                title: String(localized: "Last day of \(monthName(month))", bundle: .module),
                body: String(
                    localized: "Clear and reconcile your accounts and look over the plan, so \(monthName(month.next)) starts clean.",
                    bundle: .module
                )
            )
        }
    }

    private func monthStarts() -> [Reminder] {
        upcomingMonths().map { month in
            let first = month.next
            return Reminder(
                id: "monthStart.\(first.description)",
                kind: .monthStart,
                fireDate: at(preferences.morningHour, on: first.firstDay),
                title: String(localized: "\(monthName(first)) has begun", bundle: .module),
                body: String(localized: "Give this month's money a job: assign what is ready.", bundle: .module)
            )
        }
    }

    private func quiet(_ facts: ReminderFacts) -> Reminder? {
        guard let last = facts.lastEntryAt else { return nil }
        // Keyed to the entry, so it comes once per quiet spell rather than every evening after.
        return Reminder(
            id: "quiet.\(Int(last.timeIntervalSince1970))",
            kind: .quiet,
            fireDate: at(
                preferences.eveningHour, on: last.asBudgetDay(in: calendar.timeZone),
                plusDays: ReminderPreferences.quietAfterDays
            ),
            title: String(localized: "Anything to write down?", bundle: .module),
            body: String(
                localized: "Nothing has been entered for a few days. A minute now keeps the plan true.",
                bundle: .module
            )
        )
    }

    private func reconcile(_ facts: ReminderFacts, ledger: ReminderLedger) -> Reminder? {
        guard let oldest = facts.unreconciled.map(\.oldest).min() else { return nil }
        let fire = nagDate(
            from: at(preferences.morningHour, on: oldest, plusDays: ReminderPreferences.reconcileAfterDays),
            lastSent: ledger.delivered[ReminderKind.reconcile.rawValue]
        )
        // Named only once each is a month behind by then; a fresh entry elsewhere is not a reason.
        let behind = facts.unreconciled
            .filter { at(preferences.morningHour, on: $0.oldest, plusDays: ReminderPreferences.reconcileAfterDays) <= fire }
            .map(\.account)
        return Reminder(
            id: ReminderKind.reconcile.rawValue,
            kind: .reconcile,
            fireDate: fire,
            title: String(localized: "Time to reconcile", bundle: .module),
            body: String(
                localized: "Entries over a month old, not yet checked against a statement: \(ListFormatter.localizedString(byJoining: behind)).",
                bundle: .module
            )
        )
    }

    private func backup(_ facts: ReminderFacts, ledger: ReminderLedger) -> Reminder? {
        guard let last = facts.lastBackupAt else { return nil }
        let fire = nagDate(
            from: at(
                preferences.morningHour, on: last.asBudgetDay(in: calendar.timeZone),
                plusDays: ReminderPreferences.backupAfterDays
            ),
            lastSent: ledger.delivered[ReminderKind.backup.rawValue]
        )
        return Reminder(
            id: ReminderKind.backup.rawValue,
            kind: .backup,
            fireDate: fire,
            title: String(localized: "Save a backup", bundle: .module),
            body: String(
                localized: "No backup has been saved on this device for over a month. A copy in Files is one you can always go back to.",
                bundle: .module
            )
        )
    }

    // MARK: - Dates

    /// When a nag next comes: once the condition has stood long enough, not before the next
    /// morning, and a week after the last one.
    private func nagDate(from threshold: Date, lastSent: Date?) -> Date {
        var fire = max(threshold, nextSlot(preferences.morningHour))
        if let lastSent {
            fire = max(fire, at(
                preferences.morningHour, on: lastSent.asBudgetDay(in: calendar.timeZone),
                plusDays: ReminderPreferences.nagEveryDays
            ))
        }
        return fire
    }

    /// `hour` o'clock local time on a budget day's calendar date, `plusDays` later.
    ///
    /// A budget day is midday UTC; its date is read in UTC, where it lives, and the hour placed in
    /// the local calendar. Read locally, the 1st at UTC+14 would already be the 2nd.
    func at(_ hour: Int, on budgetDay: Date, plusDays: Int = 0) -> Date {
        let day = Calendar.gregorianUTC.date(byAdding: .day, value: plusDays, to: budgetDay) ?? budgetDay
        let parts = Calendar.gregorianUTC.dateComponents([.year, .month, .day], from: day)
        return calendar.date(
            from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: hour)
        ) ?? day
    }

    /// The next time it is `hour` o'clock: today if that is still to come, otherwise tomorrow.
    private func nextSlot(_ hour: Int) -> Date {
        let today = now.asBudgetDay(in: calendar.timeZone)
        let slot = at(hour, on: today)
        return slot > now ? slot : at(hour, on: today, plusDays: 1)
    }

    /// This month and the next: enough for a month-end, a month-start and a card payment to be
    /// waiting whatever day it is, and re-planned long before the next ones are needed.
    private func upcomingMonths() -> [YearMonth] {
        let month = YearMonth.current(in: calendar.timeZone, now: now)
        return [month, month.next]
    }

    private func daysIn(_ month: YearMonth) -> Int {
        Calendar.gregorianUTC.range(of: .day, in: .month, for: month.firstDay)?.count ?? 28
    }

    private func dayKey(_ budgetDay: Date) -> String {
        let parts = Calendar.gregorianUTC.dateComponents([.year, .month, .day], from: budgetDay)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// "25 October", in the reader's language and order.
    private func dayName(_ budgetDay: Date) -> String {
        formatted(budgetDay, template: "dMMMM")
    }

    /// "October".
    private func monthName(_ month: YearMonth) -> String {
        formatted(month.firstDay, template: "LLLL")
    }

    private func formatted(_ budgetDay: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = .gregorianUTC
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: budgetDay)
    }
}
