import Foundation
import EmbersCore
import EmbersData
import SwiftData

/// Reminders are planned from what the plan knows, at local hours, and each comes when it should
/// and no more often.
///
/// Dubai, UTC+4 all year: far enough from UTC that reading a budget day in the wrong zone moves a
/// reminder to the wrong hour, and no daylight saving to make a fixed instant ambiguous.
@MainActor
func reminderChecks(_ check: Checker) {
    var dubai = Calendar(identifier: .gregorian)
    dubai.timeZone = TimeZone(identifier: "Asia/Dubai")!
    let usd = CurrencyRegistry.usd

    /// An instant given as Dubai's wall clock.
    func local(_ month: Int, _ day: Int, _ hour: Int, year: Int = 2026) -> Date {
        dubai.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func planner(at now: Date, enabled: Set<ReminderKind>) -> ReminderPlanner {
        ReminderPlanner(
            preferences: ReminderPreferences(enabled: enabled),
            calendar: dubai,
            now: now,
            locale: Locale(identifier: "en_US")
        )
    }

    let rent = ReminderFacts.Scheduled(
        transactionID: UUID(), date: .budgetDay(year: 2026, month: 10, day: 30), name: "Landlord", amount: -150_000
    )

    check.suite("Reminders are planned for the right moment") {
        check.test("a payment is announced at nine on its own day, local time") {
            let facts = ReminderFacts(currency: usd, needsAttention: 2, scheduled: [rent])
            let plan = planner(at: local(10, 24, 8), enabled: [.due]).plan(facts, ledger: ReminderLedger())
            check.expect(plan.count, 1)
            check.expect(plan.first?.fireDate, local(10, 30, 9), "the 30th at nine in Dubai, not in UTC")
            check.expect(plan.first?.transactionID, rent.transactionID)
            check.expect(plan.first?.badge, 3, "what is already waiting, and this one")
            check.expectTrue(plan.first?.title.contains("Landlord") == true)
        }

        check.test("a payment already announced is not announced again") {
            let facts = ReminderFacts(currency: usd, scheduled: [rent])
            let first = planner(at: local(10, 24, 8), enabled: [.due]).plan(facts, ledger: ReminderLedger())
            var ledger = ReminderLedger()
            ledger.record(first)
            ledger.settle(now: local(10, 30, 10))
            // Moved back a day in the editor would make it a new occasion; left alone, it is done.
            let later = planner(at: local(10, 30, 8), enabled: [.due]).plan(facts, ledger: ledger)
            check.expect(later.count, 0)
        }

        check.test("a short category is mentioned three days ahead, or the next morning if found late") {
            let shortfall = ReminderFacts.Shortfall(
                categoryID: UUID(), category: "Rent", needed: 20_000, firstDue: .budgetDay(year: 2026, month: 10, day: 30)
            )
            let facts = ReminderFacts(currency: usd, shortfalls: [shortfall])
            let early = planner(at: local(10, 20, 8), enabled: [.shortfall]).plan(facts, ledger: ReminderLedger())
            check.expect(early.first?.fireDate, local(10, 27, 9))
            let late = planner(at: local(10, 28, 10), enabled: [.shortfall]).plan(facts, ledger: ReminderLedger())
            check.expect(late.first?.fireDate, local(10, 29, 9))
            let tooLate = planner(at: local(10, 29, 10), enabled: [.shortfall]).plan(facts, ledger: ReminderLedger())
            check.expect(tooLate.count, 0, "the payment's own reminder says it from here")
        }

        check.test("a card payment comes three days before the 25th, and only when a card owes") {
            let owing = ReminderFacts(currency: usd, cardsOwing: ["Visa", "Amex"])
            let october = planner(at: local(10, 1, 8), enabled: [.cardPayment]).plan(owing, ledger: ReminderLedger())
            check.expect(october.first?.fireDate, local(10, 22, 9))
            check.expectTrue(october.first?.body.contains("Visa") == true)
            let pastIt = planner(at: local(10, 24, 8), enabled: [.cardPayment]).plan(owing, ledger: ReminderLedger())
            check.expect(pastIt.map(\.fireDate), [local(11, 22, 9)], "October's has gone; November's waits")
            let paid = ReminderFacts(currency: usd)
            check.expect(planner(at: local(10, 1, 8), enabled: [.cardPayment]).plan(paid, ledger: ReminderLedger()).count, 0)
        }

        check.test("a payment day past the month's end falls on its last day") {
            var preferences = ReminderPreferences(enabled: [.cardPayment])
            preferences.cardPaymentDay = 31
            let planner = ReminderPlanner(preferences: preferences, calendar: dubai, now: local(2, 1, 8, year: 2027))
            let plan = planner.plan(ReminderFacts(currency: usd, cardsOwing: ["Visa"]), ledger: ReminderLedger())
            check.expect(plan.first?.fireDate, local(2, 25, 9, year: 2027), "three days before the 28th")
        }

        check.test("the month's last evening and the next month's first morning") {
            let plan = planner(at: local(10, 24, 8), enabled: [.monthEnd, .monthStart])
                .plan(ReminderFacts(currency: usd), ledger: ReminderLedger())
            check.expectTrue(plan.contains { $0.kind == .monthEnd && $0.fireDate == local(10, 31, 19) })
            check.expectTrue(plan.contains { $0.kind == .monthStart && $0.fireDate == local(11, 1, 9) })
        }

        check.test("a quiet spell is mentioned once, three evenings after the last entry") {
            let facts = ReminderFacts(currency: usd, lastEntryAt: local(10, 20, 15))
            let plan = planner(at: local(10, 21, 8), enabled: [.quiet]).plan(facts, ledger: ReminderLedger())
            check.expect(plan.first?.fireDate, local(10, 23, 19))
            check.expect(planner(at: local(10, 24, 8), enabled: [.quiet]).plan(facts, ledger: ReminderLedger()).count, 0)
        }

        check.test("nothing at all for a store with no plan") {
            let facts = ReminderFacts(currency: usd, holdsAPlan: false, lastEntryAt: local(10, 20, 15))
            check.expect(planner(at: local(10, 21, 8), enabled: Set(ReminderKind.allCases)).plan(facts, ledger: ReminderLedger()).count, 0)
        }
    }

    check.suite("Reconciling is asked for only where there is something to check") {
        let behind = ReminderFacts.Unreconciled(
            accountID: UUID(), account: "Checking", oldest: .budgetDay(year: 2026, month: 9, day: 1)
        )
        let recent = ReminderFacts.Unreconciled(
            accountID: UUID(), account: "Wallet", oldest: .budgetDay(year: 2026, month: 10, day: 20)
        )

        check.test("an account a month behind is named, the next morning") {
            let facts = ReminderFacts(currency: usd, unreconciled: [behind, recent])
            let plan = planner(at: local(10, 24, 8), enabled: [.reconcile]).plan(facts, ledger: ReminderLedger())
            check.expect(plan.first?.fireDate, local(10, 24, 9))
            check.expectTrue(plan.first?.body.contains("Checking") == true)
            check.expectTrue(plan.first?.body.contains("Wallet") == false, "not a month behind yet")
        }

        check.test("nothing is asked while every account is reconciled, however long ago") {
            let facts = ReminderFacts(currency: usd, unreconciled: [])
            check.expect(planner(at: local(10, 24, 8), enabled: [.reconcile]).plan(facts, ledger: ReminderLedger()).count, 0)
        }

        check.test("asked again a week later, not every morning the app is opened") {
            let facts = ReminderFacts(currency: usd, unreconciled: [behind])
            let first = planner(at: local(10, 24, 8), enabled: [.reconcile]).plan(facts, ledger: ReminderLedger())
            var ledger = ReminderLedger()
            ledger.record(first)
            ledger.settle(now: local(10, 25, 8))
            let next = planner(at: local(10, 25, 8), enabled: [.reconcile]).plan(facts, ledger: ledger)
            check.expect(next.first?.fireDate, local(10, 31, 9))
        }

        check.test("a backup a month old is asked for, and a recent one is not yet") {
            let old = ReminderFacts(currency: usd, lastBackupAt: local(9, 1, 12))
            check.expect(planner(at: local(10, 24, 8), enabled: [.backup]).plan(old, ledger: ReminderLedger()).first?.fireDate, local(10, 24, 9))
            let fresh = ReminderFacts(currency: usd, lastBackupAt: local(10, 20, 12))
            check.expect(planner(at: local(10, 24, 8), enabled: [.backup]).plan(fresh, ledger: ReminderLedger()).first?.fireDate, local(11, 19, 9))
        }
    }

    check.suite("What reminders are read from") {
        check.test("reads payments waiting, cards owing and accounts with unreconciled entries, on disk") {
            let url = URL.temporaryDirectory.appending(path: "reminders-\(UUID().uuidString).store")
            let context = ModelContext(try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url))
            let today = Date.budgetDay(year: 2026, month: 10, day: 17)
            let cutoff = Date.endOfBudgetDay(containing: today, in: TimeZone(secondsFromGMT: 0)!)
            let october = YearMonth(year: 2026, month: 10)

            let group = CategoryGroup(name: "Bills")
            let rentCategory = BudgetCategoryModel(name: "Rent", group: group)
            let groceries = BudgetCategoryModel(name: "Groceries", group: group)
            let checking = Account(name: "Checking", type: .checking)
            let savings = Account(name: "Savings", type: .savings)
            let visa = Account(name: "Visa", type: .creditCard)
            for model in [group, rentCategory, groceries] as [any PersistentModel] { context.insert(model) }
            for account in [checking, savings, visa] { context.insert(account) }
            let landlord = Payee(name: "Landlord")
            context.insert(landlord)

            // Savings has only its starting balance, reconciled: nothing to check.
            context.insert(LedgerTransaction(date: .budgetDay(year: 2026, month: 8, day: 1), amountMinor: 500_000, cleared: .reconciled, account: savings))
            context.insert(LedgerTransaction(date: .budgetDay(year: 2026, month: 9, day: 2), amountMinor: 900_000, cleared: .cleared, account: checking))
            context.insert(LedgerTransaction(date: .budgetDay(year: 2026, month: 10, day: 3), amountMinor: -4_000, account: visa, category: groceries))
            let scheduled = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 10, day: 30), amountMinor: -150_000,
                account: checking, payee: landlord, category: rentCategory
            )
            context.insert(scheduled)
            try context.save()
            try RecurrenceWriter.markScheduled(in: context, asOf: cutoff)

            let result = BudgetEngine().compute(try BudgetInputBuilder.build(from: context), asOf: cutoff, through: october)
            let facts = try ReminderFactsReader.read(
                from: context, result: result, asOf: cutoff, month: october, currency: usd, lastBackupAt: nil
            )
            check.expect(facts.scheduled.map(\.transactionID), [scheduled.identifier])
            check.expect(facts.scheduled.first?.name, "Landlord")
            check.expect(facts.cardsOwing, ["Visa"])
            check.expect(Set(facts.unreconciled.map(\.account)), ["Checking", "Visa"], "not Savings")
            check.expect(facts.unreconciled.first { $0.account == "Checking" }?.oldest, .budgetDay(year: 2026, month: 9, day: 2))
            check.expect(facts.shortfalls.map(\.category), ["Rent"], "nothing assigned, and rent to come")
            check.expect(facts.shortfalls.first?.firstDue, .budgetDay(year: 2026, month: 10, day: 30))
            check.expectTrue(facts.lastEntryAt != nil)
        }
    }
}
