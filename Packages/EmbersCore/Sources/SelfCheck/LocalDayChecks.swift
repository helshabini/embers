import Foundation
import EmbersCore
import EmbersData
import SwiftData

/// Which day — and so which month — an entry belongs to, for someone who is not on UTC.
///
/// Budget dates live in UTC so a month label cannot drift when a device changes timezone. That is
/// right for storage and wrong for the question "what day is it": east of Greenwich the first hours
/// of a day are still yesterday in UTC. At UTC+4 on the 1st of October, asking the raw instant opened
/// the plan on September and filed the morning's shopping under it.
@MainActor
func localDayChecks(_ check: Checker) {
    let gulf = TimeZone(secondsFromGMT: 4 * 3600)!
    let london = TimeZone(secondsFromGMT: 0)!
    let samoa = TimeZone(secondsFromGMT: -11 * 3600)!

    /// 1 October 2026, 00:33 at UTC+4 — still 20:33 on 30 September in UTC.
    let earlyOctober = Date(timeIntervalSince1970: 1_790_800_380)

    check.suite("The day it is where the person is") {
        check.test("the small hours of the 1st are the 1st, not the last of the month before") {
            let parts = Calendar.gregorianUTC.dateComponents(
                [.year, .month, .day], from: earlyOctober
            )
            check.expect(parts.month, 9, "the instant really is September in UTC")
            check.expect(parts.day, 30)

            let today = Date.todayAsBudgetDay(in: gulf, now: earlyOctober)
            let asBudgetDay = Calendar.gregorianUTC.dateComponents(
                [.year, .month, .day], from: today
            )
            check.expect(asBudgetDay.month, 10, "but the person is having the 1st of October")
            check.expect(asBudgetDay.day, 1)
        }

        check.test("the plan opens on the month the person is in") {
            check.expect(
                YearMonth.current(in: gulf, now: earlyOctober),
                YearMonth(year: 2026, month: 10),
                "opening on September on the 1st of October is the reported fault"
            )
            check.expect(
                YearMonth.current(in: london, now: earlyOctober),
                YearMonth(year: 2026, month: 9),
                "and in London it really is still September"
            )
        }

        check.test("works west of Greenwich too, where the day runs behind") {
            // 1 October 03:00 UTC is still 16:00 on 30 September at UTC-11.
            let lateSeptember = Date(timeIntervalSince1970: 1_790_823_600)
            check.expect(
                Calendar.gregorianUTC.dateComponents([.month, .day], from: lateSeptember).day, 1
            )
            check.expect(
                YearMonth.current(in: samoa, now: lateSeptember),
                YearMonth(year: 2026, month: 9),
                "a month must not start early for someone behind UTC either"
            )
        }

        check.test("an entry made then counts against that month's budget") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let checking = Account(name: "Checking", type: .checking)
            let group = CategoryGroup(name: "Immediate Obligations")
            let groceries = BudgetCategoryModel(name: "Groceries", group: group)
            context.insert(checking)
            context.insert(group)
            context.insert(groceries)
            context.insert(
                LedgerTransaction(
                    date: .todayAsBudgetDay(in: gulf, now: earlyOctober),
                    amountMinor: -8_000, account: checking, category: groceries
                )
            )
            try context.save()

            let result = BudgetEngine().compute(
                try BudgetInputBuilder.build(from: context),
                asOf: .endOfBudgetDay(containing: earlyOctober, in: gulf),
                through: YearMonth(year: 2026, month: 10)
            )
            check.expect(
                result.state(of: groceries.identifier, in: YearMonth(year: 2026, month: 10)).activity,
                -8_000,
                "shopping done on the 1st belongs to that month"
            )
            check.expect(
                result.state(of: groceries.identifier, in: YearMonth(year: 2026, month: 9)).activity,
                0,
                "and not to the one that just ended"
            )
        }
    }
}
