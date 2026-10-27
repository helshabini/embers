import Foundation
import EmbersCore

func moneyChecks(_ check: Checker) {
    let usd = CurrencyRegistry.usd

    check.suite("Money") {
        check.test("parses the amount formats a YNAB export uses") {
            check.expect(Money.parse("$0.00", currency: usd)?.minorUnits, 0)
            check.expect(Money.parse("$90.00", currency: usd)?.minorUnits, 9000)
            check.expect(Money.parse("$6003.20", currency: usd)?.minorUnits, 600_320)
            check.expect(Money.parse("-$584.59", currency: usd)?.minorUnits, -58459)
            check.expect(Money.parse("$1,234.56", currency: usd)?.minorUnits, 123_456)
            check.expect(Money.parse("($584.59)", currency: usd)?.minorUnits, -58459)
            check.expect(Money.parse("584.59-", currency: usd)?.minorUnits, -58459)
        }

        check.test("rejects input with no digits") {
            check.expectNil(Money.parse("", currency: usd))
            check.expectNil(Money.parse("$", currency: usd))
            check.expectNil(Money.parse("   ", currency: usd))
        }

        check.test("respects each currency's minor-unit digits") {
            let jpy = CurrencyRegistry.currency(forCode: "JPY")
            let kwd = CurrencyRegistry.currency(forCode: "KWD")
            check.expect(jpy.minorUnitDigits, 0)
            check.expect(kwd.minorUnitDigits, 3)
            check.expect(Money.parse("1500", currency: jpy)?.minorUnits, 1500)
            check.expect(Money.parse("1.234", currency: kwd)?.minorUnits, 1234)
            check.expect(Money.parse("100.50", currency: jpy)?.minorUnits, 101)
        }

        check.test("rounds excess fraction digits half-up away from zero") {
            check.expect(Money.parse("1.005", currency: usd)?.minorUnits, 101)
            check.expect(Money.parse("1.004", currency: usd)?.minorUnits, 100)
            check.expect(Money.parse("-1.005", currency: usd)?.minorUnits, -101)
        }

        check.test("arithmetic stays exact in minor units") {
            let a = Money(minorUnits: 1999, currency: usd)
            let b = Money(minorUnits: 1, currency: usd)
            check.expect((a + b).minorUnits, 2000)
            check.expect((a - b).minorUnits, 1998)
            check.expect((-a).minorUnits, -1999)
            check.expectTrue(a > b)
        }

        // The export's account-name suffixes mix real currencies with property codes.
        check.test("validates ISO currency codes") {
            check.expectTrue(CurrencyRegistry.isValidCode("EGP"), "EGP")
            check.expectTrue(CurrencyRegistry.isValidCode("AED"), "AED")
            check.expectTrue(CurrencyRegistry.isValidCode("KES"), "KES")
            check.expectTrue(!CurrencyRegistry.isValidCode("PH"), "PH is not a currency")
            check.expectTrue(!CurrencyRegistry.isValidCode("LV"), "LV is not a currency")
        }
    }

    check.suite("YearMonth") {
        check.test("parses YNAB's month labels and its own format") {
            check.expect(YearMonth.parse("Aug 2019"), YearMonth(year: 2019, month: 8))
            check.expect(YearMonth.parse("Sep 2026"), YearMonth(year: 2026, month: 9))
            check.expect(YearMonth.parse("2026-09"), YearMonth(year: 2026, month: 9))
            check.expect(YearMonth.parse("December 2020"), YearMonth(year: 2020, month: 12))
            check.expectNil(YearMonth.parse("nonsense"))
            check.expectNil(YearMonth.parse("2026-13"))
        }

        check.test("crosses year boundaries when adding months") {
            let december = YearMonth(year: 2026, month: 12)
            check.expect(december.next, YearMonth(year: 2027, month: 1))
            check.expect(YearMonth(year: 2027, month: 1).previous, december)
            check.expect(december.adding(months: 13), YearMonth(year: 2028, month: 1))
            check.expect(december.adding(months: -12), YearMonth(year: 2025, month: 12))
        }

        check.test("orders chronologically and prints sortably") {
            check.expectTrue(YearMonth(year: 2019, month: 8) < YearMonth(year: 2019, month: 9))
            check.expectTrue(YearMonth(year: 2019, month: 12) < YearMonth(year: 2020, month: 1))
            check.expect(YearMonth(year: 2026, month: 9).description, "2026-09")
        }

        check.test("builds an inclusive ascending range") {
            let months = YearMonth.range(
                from: YearMonth(year: 2026, month: 11),
                through: YearMonth(year: 2027, month: 2)
            )
            check.expect(months.count, 4)
            check.expect(months.first, YearMonth(year: 2026, month: 11))
            check.expect(months.last, YearMonth(year: 2027, month: 2))
            check.expectTrue(
                YearMonth.range(
                    from: YearMonth(year: 2027, month: 2),
                    through: YearMonth(year: 2026, month: 11)
                ).isEmpty
            )
        }

        check.test("derives the month from a date") {
            let date = try check.unwrap(YNABExportParser.parseDate("08/10/2027"))
            check.expect(YearMonth(containing: date), YearMonth(year: 2027, month: 8))
        }
    }
}
