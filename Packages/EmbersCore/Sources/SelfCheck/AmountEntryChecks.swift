import Foundation
import EmbersCore

private let usd = CurrencyRegistry.usd
private let egp = CurrencyRegistry.currency(forCode: "EGP")
private let aed = CurrencyRegistry.currency(forCode: "AED")
private let jpy = CurrencyRegistry.currency(forCode: "JPY")

private let quote = ExchangeRateQuote(
    baseCode: "USD",
    asOf: Date(timeIntervalSince1970: 1_790_000_000),
    providerName: "open.er-api.com",
    rates: ["EGP": 52.070874, "AED": 3.6725, "JPY": 156.25]
)

func amountEntryChecks(_ check: Checker) {
    check.suite("Amount entry") {
        check.test("types digits as minor units") {
            var entry = AmountEntry(baseCurrency: usd, accountCurrency: usd)
            check.expectTrue(entry.isEmpty)
            for digit in "1234" { entry.append(digit: digit) }
            check.expect(entry.enteredAmount, 1234)
            check.expect(entry.enteredMoney.formatted(showCurrencySymbol: false), "12.34")
            entry.deleteLastDigit()
            check.expect(entry.enteredAmount, 123)
            entry.clear()
            check.expectTrue(entry.isEmpty)
            check.expect(entry.enteredAmount, 0)
        }

        check.test("ignores a leading zero and non-digits") {
            var entry = AmountEntry(baseCurrency: usd, accountCurrency: usd)
            entry.append(digit: "0")
            check.expectTrue(entry.isEmpty)
            entry.append(digit: "x")
            check.expectTrue(entry.isEmpty)
            entry.append(digit: "5")
            entry.append(digit: "0")
            check.expect(entry.enteredAmount, 50)
        }

        check.test("defaults to the account's currency, where no fee applies") {
            let entry = AmountEntry(baseCurrency: usd, accountCurrency: aed, feePercent: 1.5, quote: quote)
            check.expect(entry.enteredCurrency.code, "AED")
            check.expect(entry.feeApplies, false)
            check.expect(entry.effectiveFeePercent, 0)
        }

        // Spending EGP on an AED card: converted to the plan's USD, then marked up 1.5%.
        check.test("applies the fee once the entered currency differs from the account's") {
            var entry = AmountEntry(baseCurrency: usd, accountCurrency: aed, feePercent: 1.5, quote: quote)
            entry.enteredCurrency = egp
            entry.setEnteredAmount(100_000)
            check.expect(entry.feeApplies, true)
            check.expect(entry.effectiveFeePercent, 1.5)
            check.expect(entry.signedBaseAmount, -1_949)
            check.expect(entry.feeMoney?.minorUnits, 29)
        }

        // The worked example from the brief.
        check.test("marks up a USD charge on an EGP account by 3%") {
            var entry = AmountEntry(baseCurrency: usd, accountCurrency: egp, feePercent: 3, quote: quote)
            entry.enteredCurrency = usd
            entry.setEnteredAmount(10_000)
            check.expect(entry.feeApplies, true)
            check.expect(entry.signedBaseAmount, -10_300)
            check.expect(entry.feeMoney?.minorUnits, 300)
            check.expect(entry.isPlainBaseCurrencyEntry, false)
        }

        check.test("needs no conversion when the plan's own currency is typed on a matching account") {
            var entry = AmountEntry(baseCurrency: usd, accountCurrency: usd, feePercent: 3, quote: quote)
            entry.setEnteredAmount(4_000)
            check.expectTrue(entry.isPlainBaseCurrencyEntry)
            check.expect(entry.signedBaseAmount, -4_000)
            check.expectNil(entry.feeMoney)
            check.expectNil(entry.rateAgeInDays())
        }

        check.test("flips between outflow and inflow") {
            var entry = AmountEntry(baseCurrency: usd, accountCurrency: usd)
            entry.setEnteredAmount(2_500)
            check.expect(entry.signedBaseAmount, -2_500)
            entry.toggleDirection()
            check.expect(entry.signedBaseAmount, 2_500)
        }

        check.test("reports a missing rate instead of storing a wrong amount") {
            var entry = AmountEntry(baseCurrency: usd, accountCurrency: usd, quote: quote)
            entry.enteredCurrency = CurrencyRegistry.currency(forCode: "XYZ")
            entry.setEnteredAmount(1_000)
            check.expectTrue(entry.isMissingRate)
            check.expectNil(entry.conversion())
            check.expect(entry.signedBaseAmount, 0)
        }

        check.test("accepts a manual rate and marks it as one") {
            var entry = AmountEntry(baseCurrency: usd, accountCurrency: usd, quote: nil)
            entry.enteredCurrency = egp
            entry.setEnteredAmount(100_000)
            check.expectTrue(entry.isMissingRate, "no quote yet")
            entry.manualRate = 0.02
            check.expect(entry.isMissingRate, false)
            check.expect(entry.signedBaseAmount, -2_000)
            check.expect(entry.conversion()?.isManualRate, true)
            check.expectNil(entry.rateAgeInDays(), "a manual rate has no staleness")
        }

        check.test("reports how stale a cached rate is") {
            var entry = AmountEntry(baseCurrency: usd, accountCurrency: usd, quote: quote)
            entry.enteredCurrency = egp
            let threeDaysLater = quote.asOf.addingTimeInterval(60 * 60 * 24 * 3)
            check.expect(entry.rateAgeInDays(asOf: threeDaysLater), 3)
        }

        check.test("respects a zero-decimal currency on the keypad") {
            var entry = AmountEntry(baseCurrency: usd, accountCurrency: usd, quote: quote)
            entry.enteredCurrency = jpy
            for digit in "1500" { entry.append(digit: digit) }
            check.expect(entry.enteredAmount, 1500)
            check.expect(entry.enteredMoney.formatted(showCurrencySymbol: false), "1,500")
            // 1500 ÷ 156.25 = 9.60
            check.expect(entry.signedBaseAmount, -960)
        }

        check.test("offers the account and plan currencies first") {
            let entry = AmountEntry(baseCurrency: usd, accountCurrency: aed)
            check.expect(entry.suggestedCurrencyCodes(recent: ["EGP", "AED"]), ["AED", "USD", "EGP"])
        }
    }
}
