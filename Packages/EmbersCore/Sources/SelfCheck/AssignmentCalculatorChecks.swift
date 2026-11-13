import Foundation
import EmbersCore

/// The keypad's arithmetic, which decides what lands in a category.
@MainActor
func assignmentCalculatorChecks(_ check: Checker) {
    let usd = CurrencyRegistry.usd
    let jpy = CurrencyRegistry.currency(forCode: "JPY")

    func typed(_ keys: String, from start: MinorUnits = 0, in currency: Currency = CurrencyRegistry.usd) -> AssignmentCalculator {
        var calculator = AssignmentCalculator(startingAt: start, currency: currency)
        for key in keys {
            if let op = AssignmentCalculator.Operator(rawValue: key) {
                calculator.append(op)
            } else if key == "." {
                calculator.appendDecimalPoint()
            } else if key == "<" {
                calculator.deleteLast()
            } else {
                calculator.append(digit: key)
            }
        }
        return calculator
    }

    check.suite("The assign keypad") {
        check.test("opens on what is assigned, which a digit replaces and an operator works on") {
            check.expect(typed("", from: 12_050).text, "120.5")
            check.expect(typed("75", from: 12_050).result, 7_500, "typing starts a new amount")
            check.expect(typed("+50", from: 12_050).result, 17_050, "another 50 on top")
            check.expect(typed("÷2", from: 12_050).result, 6_025, "half of it")
        }

        check.test("works × and ÷ before + and −") {
            check.expect(typed("100+20×3").result, 16_000)
            check.expect(typed("100−20÷4").result, 9_500)
            check.expect(typed("1200÷12").result, 10_000, "a year's bill, a month at a time")
        }

        check.test("rounds to the currency, half away from zero") {
            check.expect(typed("10÷3").result, 333)
            check.expect(typed("0.05÷2").result, 3)
            check.expect(typed("1000÷3", in: jpy).result, 333, "a yen has no cents")
        }

        check.test("allows no more decimals than the currency has") {
            check.expect(typed("1.239").text, "1.23")
            check.expect(typed("12.5", in: jpy).text, "125", "a yen amount has no decimal point")
            check.expect(typed("..5").text, "0.5")
        }

        check.test("a trailing operator waits for its number, and a second replaces it") {
            check.expect(typed("100+").result, 10_000)
            check.expect(typed("100+×2").text, "100×2")
            check.expect(typed("100+×2").result, 20_000)
        }

        check.test("can go below zero, but not divide by it") {
            check.expect(typed("−50").result, -5_000)
            check.expect(typed("+10", from: -5_000).result, -4_000, "a negative start reads as a sum")
            check.expectNil(typed("5÷0").result)
            check.expect(typed("").result, 0, "nothing typed is nothing assigned")
            check.expect(typed("5<<").result, 0)
            check.expect(typed("+10").result, 1_000, "a sum on nothing assigned starts from zero")
        }

        check.test("understands a sum typed into a field, in the reader's own marks") {
            let us = Locale(identifier: "en_US")
            let german = Locale(identifier: "de_DE")
            func read(_ text: String, _ locale: Locale = us) -> AssignmentCalculator.Typed {
                AssignmentCalculator.read(typed: text, currency: usd, locale: locale)
            }
            check.expect(read("100 + 50"), .sum(15_000))
            check.expect(read("$1,200/12"), .sum(10_000))
            check.expect(read("12,50*2", german), .sum(2_500))
            check.expect(read("-1,234.50"), .plain, "a plain amount is the ordinary parser's")
            check.expect(read("50-"), .plain, "a trailing minus is a negative amount, not half a sum")
        }

        // Handed to the ordinary parser, these were saved as 1,000.00, −1,002.00 and −10,050.00.
        check.test("refuses a sum that comes to nothing, rather than reading part of it") {
            let us = Locale(identifier: "en_US")
            for text in ["100/0", "100*-2", "100+50-", "+"] {
                check.expect(AssignmentCalculator.read(typed: text, currency: usd, locale: us), .malformed, text)
            }
        }
    }
}
