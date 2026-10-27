import Foundation
import EmbersCore
import EmbersData
import SwiftData

@MainActor
func enhancementChecks(_ check: Checker) {
    let january = YearMonth(year: 2026, month: 1)

    check.suite("Currency symbols") {
        // "US$1,234.56" is noise on every row of a budget that only uses one currency.
        check.test("uses the short symbol next to a figure") {
            let usd = CurrencyRegistry.usd
            check.expect(usd.symbol, "$")
            let formatted = Money(minorUnits: 123_456, currency: usd).formatted(locale: Locale(identifier: "en_GB"))
            check.expectTrue(formatted.contains("$"), formatted)
            check.expectTrue(!formatted.contains("US$"), formatted)
        }

        check.test("falls back to the code where no symbol exists") {
            for code in ["EGP", "AED", "KES", "GBP", "EUR", "JPY"] {
                let symbol = CurrencyRegistry.symbol(forCode: code)
                check.expectTrue(!symbol.isEmpty, code)
                check.expectTrue(symbol.count <= 3, "\(code) resolved to \(symbol)")
            }
            check.expect(CurrencyRegistry.symbol(forCode: "GBP"), "£")
            check.expect(CurrencyRegistry.symbol(forCode: "EUR"), "€")
            check.expect(CurrencyRegistry.symbol(forCode: "JPY"), "¥")
        }

        check.test("leaves the plain number alone when no symbol was asked for") {
            let formatted = Money(minorUnits: 123_456, currency: CurrencyRegistry.usd)
                .formatted(showCurrencySymbol: false)
            check.expectTrue(!formatted.contains("$"), formatted)
        }
    }

    check.suite("Ready to Assign answers one question") {
        // What it means, and what it deliberately does not: it is what has come in and not yet been
        // given a job. Spending is not assigning. Money leaving a category reduces that category,
        // and if there was nothing there to spend, the category reads overspent and the shortfall
        // comes off next month — which is where an envelope budget puts it.
        check.test("spending does not touch it; only assigning does") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let checking = Account(name: "Checking", type: .checking)
            let inflowGroup = CategoryGroup(name: "Inflow")
            let inflow = BudgetCategoryModel(
                name: "Ready to Assign", group: inflowGroup, kind: .inflowReadyToAssign
            )
            let group = CategoryGroup(name: "Immediate Obligations")
            let groceries = BudgetCategoryModel(name: "Groceries", group: group)
            for model in [checking] as [any PersistentModel] { context.insert(model) }
            context.insert(inflowGroup)
            context.insert(inflow)
            context.insert(group)
            context.insert(groceries)

            let october = YearMonth(year: 2026, month: 10)
            context.insert(
                LedgerTransaction(
                    date: .budgetDay(year: 2026, month: 10, day: 1),
                    amountMinor: 10_000, account: checking, category: inflow
                )
            )
            try context.save()

            func readyToAssign() throws -> MinorUnits {
                BudgetEngine()
                    .compute(try BudgetInputBuilder.build(from: context), through: october)
                    .readyToAssign(in: october)
            }
            check.expect(try readyToAssign(), 10_000, "a hundred dollars came in")

            // Spend ten of it without having assigned anything.
            context.insert(
                LedgerTransaction(
                    date: .budgetDay(year: 2026, month: 10, day: 2),
                    amountMinor: -1_000, account: checking, category: groceries
                )
            )
            try context.save()
            check.expect(
                try readyToAssign(), 10_000,
                "spending is not assigning: the money still has no job"
            )

            let result = BudgetEngine()
                .compute(try BudgetInputBuilder.build(from: context), through: october)
            check.expect(
                result.state(of: groceries.identifier, in: october).available, -1_000,
                "the category it came out of is what goes short"
            )
            check.expect(result.months[october]?.cashOverspending, 1_000)

            // Assigning is what moves it.
            context.insert(
                CategoryAssignment(month: october, amountMinor: 4_000, category: groceries)
            )
            try context.save()
            check.expect(try readyToAssign(), 6_000, "assigning forty leaves sixty")
        }

        check.test("overspending comes off the month after, not the month it happened") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let checking = Account(name: "Checking", type: .checking)
            let inflowGroup = CategoryGroup(name: "Inflow")
            let inflow = BudgetCategoryModel(
                name: "Ready to Assign", group: inflowGroup, kind: .inflowReadyToAssign
            )
            let group = CategoryGroup(name: "Just for Fun")
            let dining = BudgetCategoryModel(name: "Dining", group: group)
            context.insert(checking)
            context.insert(inflowGroup)
            context.insert(inflow)
            context.insert(group)
            context.insert(dining)
            context.insert(
                LedgerTransaction(
                    date: .budgetDay(year: 2026, month: 10, day: 1),
                    amountMinor: 10_000, account: checking, category: inflow
                )
            )
            context.insert(
                LedgerTransaction(
                    date: .budgetDay(year: 2026, month: 10, day: 20),
                    amountMinor: -2_500, account: checking, category: dining
                )
            )
            try context.save()

            let november = YearMonth(year: 2026, month: 11)
            let result = BudgetEngine()
                .compute(try BudgetInputBuilder.build(from: context), through: november)
            check.expect(
                result.readyToAssign(in: YearMonth(year: 2026, month: 10)), 10_000,
                "the month it happened still shows what came in and was never assigned"
            )
            check.expect(
                result.readyToAssign(in: november), 7_500,
                "and the overspend is made good out of the next month"
            )
        }
    }
    check.suite("Repeating transactions") {
        check.test("steps to the next date for each rule") {
            let start = Date.budgetDay(year: 2026, month: 1, day: 15)
            func day(_ date: Date) -> Int { Calendar.gregorianUTC.component(.day, from: date) }
            func month(_ date: Date) -> Int { Calendar.gregorianUTC.component(.month, from: date) }

            check.expect(day(Recurrence.weekly.nextDate(after: start)), 22)
            check.expect(day(Recurrence.everyOtherWeek.nextDate(after: start)), 29)
            check.expect(month(Recurrence.monthly.nextDate(after: start)), 2)
            check.expect(month(Recurrence.everyThreeMonths.nextDate(after: start)), 4)
            let yearly = Recurrence.yearly.nextDate(after: start)
            check.expect(Calendar.gregorianUTC.component(.year, from: yearly), 2027)
        }

        // A payment due on the 31st must not drift earlier for good.
        check.test("keeps the day of the month across a short month") {
            let jan31 = Date.budgetDay(year: 2026, month: 1, day: 31)
            let feb = Recurrence.monthly.nextDate(after: jan31)
            check.expect(Calendar.gregorianUTC.component(.month, from: feb), 2)
            let mar = Recurrence.monthly.nextDate(after: feb)
            check.expect(Calendar.gregorianUTC.component(.month, from: mar), 3)
        }

        check.test("catches up a schedule left alone for months") {
            let start = Date.budgetDay(year: 2026, month: 1, day: 10)
            let cutoff = Date.budgetDay(year: 2026, month: 5, day: 20)
            let next = Recurrence.monthly.nextDate(after: start, notBefore: cutoff)
            check.expectTrue(next > cutoff, "\(next)")
            check.expect(Calendar.gregorianUTC.component(.month, from: next), 6)
        }

        check.test("enters the occurrence that arrived and schedules only the next one") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let checking = Account(name: "Checking", type: .checking)
            context.insert(checking)
            let rent = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 1, day: 1),
                amountMinor: -120_000, memo: "Rent", account: checking
            )
            rent.recurrence = .monthly
            context.insert(rent)
            try context.save()

            let entered = try RecurrenceWriter.advanceDueOccurrences(
                in: context, asOf: .budgetDay(year: 2026, month: 1, day: 15)
            )
            check.expect(entered, 1)

            let all = try context.fetch(FetchDescriptor<LedgerTransaction>())
            check.expect(all.count, 2, "the one that happened, plus the next one")
            check.expect(all.filter { $0.recurrence != nil }.count, 1, "only the next one repeats")
            let scheduled = try check.unwrap(
                all.first { Calendar.gregorianUTC.component(.month, from: $0.date) == 2 }
            )
            check.expect(scheduled.recurrence, .monthly)
            check.expect(scheduled.amountMinor, -120_000)
            check.expect(scheduled.cleared, .uncleared)
            let settled = try check.unwrap(all.first { $0.recurrence == nil })
            check.expect(settled.memo, "Rent")
        }

        check.test("does not touch an occurrence that has not arrived") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let checking = Account(name: "Checking", type: .checking)
            context.insert(checking)
            let upcoming = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 6, day: 1),
                amountMinor: -5_000, account: checking
            )
            upcoming.recurrence = .monthly
            context.insert(upcoming)
            try context.save()

            let entered = try RecurrenceWriter.advanceDueOccurrences(
                in: context, asOf: .budgetDay(year: 2026, month: 1, day: 15)
            )
            check.expect(entered, 0)
            check.expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 1)
        }

        check.test("carries both sides of a repeating transfer") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let checking = Account(name: "Checking", type: .checking)
            let savings = Account(name: "Savings", type: .savings)
            context.insert(checking)
            context.insert(savings)
            let sides = TransferWriter.makeTransfer(
                amountMinor: 50_000, from: checking, to: savings,
                date: .budgetDay(year: 2026, month: 1, day: 1), in: context
            )
            sides.outgoing.recurrence = .monthly
            try context.save()

            try RecurrenceWriter.advanceDueOccurrences(
                in: context, asOf: .budgetDay(year: 2026, month: 1, day: 15)
            )
            let all = try context.fetch(FetchDescriptor<LedgerTransaction>())
            check.expect(all.count, 4, "both sides of both occurrences")

            let scheduled = all.filter { Calendar.gregorianUTC.component(.month, from: $0.date) == 2 }
            check.expect(scheduled.count, 2)
            check.expect(scheduled.reduce(0) { $0 + $1.amountMinor }, 0, "a transfer nets to nothing")
        }

        check.test("stopping a repeat leaves the entry in place") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let checking = Account(name: "Checking", type: .checking)
            context.insert(checking)
            let entry = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 6, day: 1), amountMinor: -5_000, account: checking
            )
            entry.recurrence = .weekly
            context.insert(entry)
            try context.save()

            try RecurrenceWriter.stopRepeating(entry, in: context)
            check.expectNil(entry.recurrence)
            check.expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 1)
        }
    }
}
