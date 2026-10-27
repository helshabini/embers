import Foundation
import EmbersCore
import EmbersData
import SwiftData

/// Whether a repeat rule survives being written to a real file.
///
/// The in-memory store is not the app's store. `ClearedStatus` round-tripped perfectly in memory and
/// silently lost every value on disk, so anything stored as an enum gets checked against a file.
@MainActor
func recurrencePersistenceChecks(_ check: Checker) {
    func onDisk() throws -> (URL, ModelContainer) {
        let url = URL.temporaryDirectory.appending(path: "recurrence-\(UUID().uuidString).store")
        return (url, try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url))
    }

    check.suite("Repeating a transaction, on disk") {
        check.test("a rule set on a new transaction is there when the store is reopened") {
            let (url, container) = try onDisk()
            let identifier: UUID
            do {
                let context = ModelContext(container)
                let checking = Account(name: "Checking", type: .checking)
                context.insert(checking)
                let rent = LedgerTransaction(
                    date: .budgetDay(year: 2026, month: 10, day: 1),
                    amountMinor: -120_000, memo: "Rent", account: checking
                )
                context.insert(rent)
                rent.recurrence = .monthly
                try context.save()
                identifier = rent.identifier
            }

            let reopened = ModelContext(
                try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url)
            )
            let all = try reopened.fetch(FetchDescriptor<LedgerTransaction>())
            let found = try check.unwrap(all.first { $0.identifier == identifier })
            check.expect(found.recurrence, .monthly, "the repeat rule should survive a reopen")
        }

        check.test("a rule set on a transaction that already exists is saved") {
            let (url, container) = try onDisk()
            let identifier: UUID
            do {
                let context = ModelContext(container)
                let checking = Account(name: "Checking", type: .checking)
                context.insert(checking)
                let rent = LedgerTransaction(
                    date: .budgetDay(year: 2026, month: 10, day: 1),
                    amountMinor: -120_000, memo: "Rent", account: checking
                )
                context.insert(rent)
                try context.save()
                identifier = rent.identifier

                // The editor's path: reopen an existing row and set the rule on it.
                rent.recurrence = .weekly
                try context.save()
            }

            let reopened = ModelContext(
                try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url)
            )
            let all = try reopened.fetch(FetchDescriptor<LedgerTransaction>())
            let found = try check.unwrap(all.first { $0.identifier == identifier })
            check.expect(found.recurrence, .weekly, "editing a row should store its repeat rule")
        }

        check.test("clearing a rule back to never survives too") {
            let (url, container) = try onDisk()
            do {
                let context = ModelContext(container)
                let checking = Account(name: "Checking", type: .checking)
                context.insert(checking)
                let rent = LedgerTransaction(
                    date: .budgetDay(year: 2026, month: 10, day: 1),
                    amountMinor: -120_000, account: checking
                )
                context.insert(rent)
                rent.recurrence = .monthly
                try context.save()
                rent.recurrence = nil
                try context.save()
            }

            let reopened = ModelContext(
                try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url)
            )
            let all = try reopened.fetch(FetchDescriptor<LedgerTransaction>())
            check.expectNil(try check.unwrap(all.first).recurrence, "Never should stay Never")
        }
    }
}

/// What happens to a repeat set on a transaction that has already happened.
///
/// This is the shape of a report that setting a repeat "fails": the rule is stored, and then the next
/// launch moves it onto the occurrence that has not happened yet. Nothing is lost, but the row that
/// was edited stops saying it repeats, which reads as the setting not having taken.
@MainActor
func repeatOnAPastDayChecks(_ check: Checker) {
    check.suite("A repeat set on a day that has already happened") {
        check.test("moves to the next occurrence as soon as the app is opened again") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let checking = Account(name: "Checking", type: .checking)
            context.insert(checking)

            let today = Date.budgetDay(year: 2026, month: 9, day: 30)
            let groceries = LedgerTransaction(
                date: today, amountMinor: -8_000, memo: "Groceries", account: checking
            )
            context.insert(groceries)
            groceries.recurrence = .monthly
            try context.save()

            // The rule is on the row the moment it is set.
            check.expect(groceries.recurrence, .monthly, "setting it does work")

            // Then the next launch catches schedules up.
            try RecurrenceWriter.advanceDueOccurrences(in: context, asOf: today)

            check.expectNil(
                groceries.recurrence,
                "the row that was edited stops repeating — this is what reads as a failure"
            )
            let all = try context.fetch(FetchDescriptor<LedgerTransaction>())
            check.expect(all.count, 2, "the rule moved to a new, future row")
            let scheduled = try check.unwrap(all.first { $0.recurrence != nil })
            check.expectTrue(scheduled.date > today, "and that row is in the future")
            check.expect(scheduled.memo, "Groceries")
        }

        check.test("a repeat set on a future day stays put until its day arrives") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let checking = Account(name: "Checking", type: .checking)
            context.insert(checking)
            let rent = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 10, day: 15), amountMinor: -120_000,
                account: checking
            )
            context.insert(rent)
            rent.recurrence = .monthly
            try context.save()

            try RecurrenceWriter.advanceDueOccurrences(
                in: context, asOf: .budgetDay(year: 2026, month: 9, day: 30)
            )
            check.expect(rent.recurrence, .monthly, "a future schedule is left alone")
            check.expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 1)
        }
    }
}

/// A transfer can repeat too.
///
/// The editor offers the repeat picker on a transfer and used to drop it on the way to the store, so
/// reopening the entry showed "Never" again. Only one side carries the rule: the writer rebuilds the
/// counterpart from whichever side has it, and a rule on both would enter every occurrence twice.
@MainActor
func repeatingTransferChecks(_ check: Checker) {
    let date = Date.budgetDay(year: 2026, month: 12, day: 8)

    @MainActor func twoAccounts(_ context: ModelContext) -> (Account, Account) {
        let checking = Account(name: "Checking", type: .checking)
        let savings = Account(name: "Savings", type: .savings)
        context.insert(checking)
        context.insert(savings)
        return (checking, savings)
    }

    check.suite("A transfer that repeats") {
        check.test("keeps its rule, on one side only") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, savings) = twoAccounts(context)
            let sides = TransferWriter.makeTransfer(
                amountMinor: 50_000, from: checking, to: savings, date: date,
                recurrence: .everyThreeMonths, in: context
            )
            try context.save()

            check.expect(sides.outgoing.recurrence, .everyThreeMonths)
            check.expectNil(
                sides.incoming.recurrence,
                "a rule on both sides would enter every occurrence twice"
            )
        }

        check.test("survives a real store and a reopen") {
            let url = URL.temporaryDirectory.appending(path: "transfer-\(UUID().uuidString).store")
            let identifier: UUID
            do {
                let context = ModelContext(
                    try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url)
                )
                let (checking, savings) = twoAccounts(context)
                let sides = TransferWriter.makeTransfer(
                    amountMinor: 50_000, from: checking, to: savings, date: date,
                    recurrence: .everyThreeMonths, in: context
                )
                try context.save()
                identifier = sides.outgoing.identifier
            }

            let reopened = ModelContext(
                try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url)
            )
            let all = try reopened.fetch(FetchDescriptor<LedgerTransaction>())
            let found = try check.unwrap(all.first { $0.identifier == identifier })
            check.expect(found.recurrence, .everyThreeMonths)
        }

        check.test("syncing the counterpart does not copy the rule onto it") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, savings) = twoAccounts(context)
            let sides = TransferWriter.makeTransfer(
                amountMinor: 50_000, from: checking, to: savings, date: date,
                recurrence: .monthly, in: context
            )
            try context.save()

            sides.outgoing.memo = "Rent"
            try TransferWriter.syncCounterpart(of: sides.outgoing, in: context)
            check.expect(sides.incoming.memo, "Rent", "the edit still carries across")
            check.expectNil(sides.incoming.recurrence, "but the rule stays on one side")
        }

        check.test("when its day arrives both sides of the next one are entered") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, savings) = twoAccounts(context)
            TransferWriter.makeTransfer(
                amountMinor: 50_000, from: checking, to: savings, date: date,
                recurrence: .everyThreeMonths, in: context
            )
            try context.save()

            let entered = try RecurrenceWriter.advanceDueOccurrences(in: context, asOf: date)
            check.expect(entered, 1, "one rule came due, not two")

            let all = try context.fetch(FetchDescriptor<LedgerTransaction>())
            check.expect(all.count, 4, "the pair that happened, plus the pair scheduled next")
            check.expect(
                all.filter { $0.recurrence != nil }.count, 1,
                "and still exactly one side carries the rule"
            )

            let scheduled = try check.unwrap(all.first { $0.recurrence != nil })
            let counterpart = try check.unwrap(
                all.first {
                    $0.transferPairIdentifier == scheduled.transferPairIdentifier
                        && $0.identifier != scheduled.identifier
                }
            )
            check.expect(
                counterpart.amountMinor, -scheduled.amountMinor,
                "money must not arrive from nowhere"
            )
            check.expect(scheduled.date, Date.budgetDay(year: 2027, month: 3, day: 8))
        }
    }
}

/// A repeating transfer from a budget account to a tracking one: the mortgage case.
///
/// These two sides are not mirror images. Money moving to a tracking account leaves the budget, so
/// the budget side carries a category and the tracking side carries none. Every generated occurrence
/// has to keep that, or the payment silently stops being budgeted for after the first one.
@MainActor
func repeatingMortgageChecks(_ check: Checker) {
    let december = Date.budgetDay(year: 2026, month: 12, day: 8)
    let march = Date.budgetDay(year: 2027, month: 3, day: 8)

    struct Setup {
        var context: ModelContext
        var checking: Account
        var apartment: Account
        var mortgage: BudgetCategoryModel
    }

    @MainActor func setUp() throws -> Setup {
        let context = ModelContext(try EmbersStore.inMemoryContainer())
        let checking = Account(name: "Atlas Checking", type: .checking)
        let apartment = Account(name: "Apartment", type: .otherAsset)
        let group = CategoryGroup(name: "Debt Payments")
        let mortgage = BudgetCategoryModel(name: "Mortgage", group: group)
        for model in [checking, apartment] as [any PersistentModel] { context.insert(model) }
        context.insert(group)
        context.insert(mortgage)
        return Setup(context: context, checking: checking, apartment: apartment, mortgage: mortgage)
    }

    check.suite("A repeating transfer into a tracking account") {
        check.test("the next occurrence keeps the category, so it stays budgeted for") {
            let s = try setUp()
            TransferWriter.makeTransfer(
                amountMinor: 600_320, from: s.checking, to: s.apartment, date: december,
                category: s.mortgage, recurrence: .everyThreeMonths, in: s.context
            )
            try s.context.save()

            try RecurrenceWriter.advanceDueOccurrences(in: s.context, asOf: december)

            let all = try s.context.fetch(FetchDescriptor<LedgerTransaction>())
            let scheduled = try check.unwrap(all.first { $0.recurrence != nil })
            check.expect(scheduled.date, march)
            check.expect(
                scheduled.category?.name, "Mortgage",
                "a scheduled mortgage payment that loses its category stops being budgeted for"
            )
            check.expect(scheduled.account?.name, "Atlas Checking")
            check.expect(scheduled.amountMinor, -600_320)

            let counterpart = try check.unwrap(
                all.first {
                    $0.transferPairIdentifier == scheduled.transferPairIdentifier
                        && $0.identifier != scheduled.identifier
                }
            )
            check.expect(counterpart.account?.name, "Apartment")
            check.expect(counterpart.amountMinor, 600_320)
            check.expectNil(counterpart.category, "the tracking side is outside the budget")
        }

        check.test("the budget records the payment in the month it falls due") {
            let s = try setUp()
            TransferWriter.makeTransfer(
                amountMinor: 600_320, from: s.checking, to: s.apartment, date: december,
                category: s.mortgage, recurrence: .everyThreeMonths, in: s.context
            )
            try s.context.save()
            try RecurrenceWriter.advanceDueOccurrences(in: s.context, asOf: december)

            let result = BudgetEngine().compute(
                try BudgetInputBuilder.build(from: s.context),
                through: YearMonth(year: 2027, month: 3)
            )
            check.expect(
                result.state(of: s.mortgage.identifier, in: YearMonth(year: 2026, month: 12)).activity,
                -600_320,
                "the occurrence that happened"
            )
            check.expect(
                result.state(of: s.mortgage.identifier, in: YearMonth(year: 2027, month: 3)).activity,
                0,
                "the one scheduled next counts for nothing until it is approved"
            )

            let march = try check.unwrap(
                try RecurrenceWriter.dueForApproval(in: s.context, asOf: .budgetDay(year: 2027, month: 3, day: 31)).first
            )
            try RecurrenceWriter.approve(march, in: s.context)
            let approved = BudgetEngine().compute(
                try BudgetInputBuilder.build(from: s.context),
                through: YearMonth(year: 2027, month: 3)
            )
            check.expect(
                approved.state(of: s.mortgage.identifier, in: YearMonth(year: 2027, month: 3)).activity,
                -600_320,
                "and is budgeted in the month it falls due once it is"
            )
        }

        /// The transfer can be opened from either register, and the rule lands on whichever side.
        check.test("it works when the rule sits on the tracking side") {
            let s = try setUp()
            let sides = TransferWriter.makeTransfer(
                amountMinor: 600_320, from: s.checking, to: s.apartment, date: december,
                category: s.mortgage, in: s.context
            )
            // Set from the Apartment register instead of the Checking one.
            sides.outgoing.recurrence = nil
            sides.incoming.recurrence = .everyThreeMonths
            try s.context.save()

            try RecurrenceWriter.advanceDueOccurrences(in: s.context, asOf: december)

            let all = try s.context.fetch(FetchDescriptor<LedgerTransaction>())
            let scheduled = try check.unwrap(all.first { $0.recurrence != nil })
            let counterpart = try check.unwrap(
                all.first {
                    $0.transferPairIdentifier == scheduled.transferPairIdentifier
                        && $0.identifier != scheduled.identifier
                }
            )
            check.expect(scheduled.account?.name, "Apartment")
            check.expect(
                counterpart.category?.name, "Mortgage",
                "the budget side keeps its category whichever side carries the rule"
            )
            check.expect(counterpart.amountMinor, -600_320)
        }

        check.test("a converted payment keeps what it was entered in") {
            let s = try setUp()
            let conversion = CurrencyConversion(
                enteredAmount: 300_160_00,
                enteredCurrencyCode: "EGP",
                rateToBase: 0.02,
                rateAsOf: december,
                rateSource: "test",
                isManualRate: false,
                feePercent: 0,
                convertedBeforeFee: 600_320,
                feeAmount: 0,
                baseAmount: 600_320
            )
            TransferWriter.makeTransfer(
                amountMinor: 600_320, from: s.checking, to: s.apartment, date: december,
                category: s.mortgage, conversion: conversion,
                recurrence: .everyThreeMonths, in: s.context
            )
            try s.context.save()
            try RecurrenceWriter.advanceDueOccurrences(in: s.context, asOf: december)

            let all = try s.context.fetch(FetchDescriptor<LedgerTransaction>())
            let scheduled = try check.unwrap(all.first { $0.recurrence != nil })
            check.expect(
                scheduled.conversion?.enteredCurrencyCode, "EGP",
                "a payment made in EGP goes on being made in EGP"
            )
        }
    }
}
