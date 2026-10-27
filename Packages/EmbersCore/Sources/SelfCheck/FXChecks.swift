import Foundation
import EmbersCore

private let usd = CurrencyRegistry.usd
private let egp = CurrencyRegistry.currency(forCode: "EGP")
private let aed = CurrencyRegistry.currency(forCode: "AED")
private let kes = CurrencyRegistry.currency(forCode: "KES")
private let jpy = CurrencyRegistry.currency(forCode: "JPY")

/// Live rates observed from open.er-api.com on 2026-09-29, used so the expected figures below are
/// arithmetic anyone can check by hand.
private let quote = ExchangeRateQuote(
    baseCode: "USD",
    asOf: Date(timeIntervalSince1970: 1_790_000_000),
    providerName: "open.er-api.com",
    rates: ["EGP": 52.070874, "AED": 3.6725, "KES": 129.549122, "JPY": 156.25]
)

func fxChecks(_ check: Checker) {
    let converter = CurrencyConverter(baseCurrency: usd)

    check.suite("Exchange rate quotes") {
        check.test("reads rates against the base in both directions") {
            check.expect(quote.rate(from: "USD", to: "USD"), 1)
            check.expect(quote.rate(from: "USD", to: "EGP"), 52.070874)
            check.expect(quote.rate(from: "EGP", to: "USD"), 1 / 52.070874)
        }

        check.test("crosses a pair that does not involve the base") {
            // 1 EGP in AED = (1 / 52.070874) × 3.6725
            let rate = try check.unwrap(quote.rate(from: "EGP", to: "AED"))
            check.expectTrue(abs(rate - 3.6725 / 52.070874) < 1e-12, "got \(rate)")
        }

        check.test("reports unsupported currencies rather than guessing") {
            check.expectNil(quote.rate(from: "USD", to: "XYZ"))
            check.expectTrue(quote.supports("EGP"))
            check.expectTrue(quote.supports("usd"), "the base itself is supported")
            check.expectTrue(!quote.supports("XYZ"))
        }

        check.test("measures staleness in whole days") {
            let now = quote.asOf.addingTimeInterval(60 * 60 * 24 * 3 + 120)
            check.expect(quote.ageInDays(asOf: now), 3)
            check.expect(quote.ageInDays(asOf: quote.asOf), 0)
            check.expect(quote.ageInDays(asOf: quote.asOf.addingTimeInterval(-500)), 0)
        }
    }

    check.suite("Currency conversion and FX fees") {
        // Spending a card's own currency is a domestic transaction, even though the plan is in USD.
        check.test("charges no fee when the entered currency is the account's currency") {
            let result = try converter.convert(
                enteredAmount: 20_000,
                from: aed,
                accountCurrency: aed,
                quote: quote,
                feePercent: 1.5
            )
            check.expect(result.appliedFee, false)
            check.expect(result.feePercent, 0)
            check.expect(result.feeAmount, 0)
            // 200 ÷ 3.6725 = 54.4588…
            check.expect(result.baseAmount, 5_446)
        }

        // The AED card used in Egypt: converted to USD, then marked up 1.5%.
        check.test("applies the fee when the entered currency differs from the account's") {
            let result = try converter.convert(
                enteredAmount: 100_000,
                from: egp,
                accountCurrency: aed,
                quote: quote,
                feePercent: 1.5
            )
            check.expect(result.appliedFee, true)
            // 1000 ÷ 52.070874 = 19.2046…
            check.expect(result.convertedBeforeFee, 1_920)
            // × 1.015 = 19.4927…
            check.expect(result.baseAmount, 1_949)
            check.expect(result.feeAmount, 29)
            check.expect(result.enteredCurrencyCode, "EGP")
        }

        // The worked example from the brief: an EGP account charged in USD at 3%.
        check.test("marks up a USD charge on an EGP account by 3%") {
            let result = try converter.convert(
                enteredAmount: 10_000,
                from: usd,
                accountCurrency: egp,
                quote: quote,
                feePercent: 3
            )
            check.expect(result.rateToBase, 1)
            check.expect(result.convertedBeforeFee, 10_000)
            check.expect(result.baseAmount, 10_300)
            check.expect(result.feeAmount, 300)
        }

        check.test("leaves a plain base-currency entry untouched") {
            let result = try converter.convert(
                enteredAmount: 4_000,
                from: usd,
                accountCurrency: usd,
                quote: quote,
                feePercent: 3
            )
            check.expect(result.baseAmount, 4_000)
            check.expect(result.feeAmount, 0)
        }

        check.test("respects the entered currency's minor-unit digits") {
            // JPY has no decimal places: 1,500 yen is 1500 minor units, not 15.00.
            let result = try converter.convert(
                enteredAmount: 1_500,
                from: jpy,
                accountCurrency: usd,
                quote: quote,
                feePercent: 0
            )
            // 1500 ÷ 156.25 = 9.60
            check.expect(result.baseAmount, 960)
        }

        check.test("keeps the fee and converted parts summing to the stored amount") {
            for entered in [1, 7, 33, 999, 123_456] as [MinorUnits] {
                let result = try converter.convert(
                    enteredAmount: entered,
                    from: kes,
                    accountCurrency: usd,
                    quote: quote,
                    feePercent: 2.75
                )
                check.expect(
                    result.convertedBeforeFee + result.feeAmount,
                    result.baseAmount,
                    "parts must sum for \(entered) KES"
                )
            }
        }

        check.test("honours a manual rate when the bank's rate differed") {
            let result = try converter.convert(
                enteredAmount: 100_000,
                from: egp,
                accountCurrency: usd,
                quote: quote,
                feePercent: 0,
                manualRate: 0.02
            )
            check.expect(result.isManualRate, true)
            check.expect(result.rateSource, "manual")
            check.expect(result.baseAmount, 2_000)
        }

        check.test("refuses to convert a currency the quote does not cover") {
            check.expectThrows {
                try converter.convert(
                    enteredAmount: 100,
                    from: CurrencyRegistry.currency(forCode: "XYZ"),
                    accountCurrency: usd,
                    quote: quote,
                    feePercent: 0
                )
            }
        }

        check.test("preserves the sign of a refund") {
            let result = try converter.convert(
                enteredAmount: -100_000,
                from: egp,
                accountCurrency: aed,
                quote: quote,
                feePercent: 1.5
            )
            check.expect(result.baseAmount, -1_949)
            check.expect(result.feeAmount, -29)
        }
    }

    check.suite("A balance counted in the account's currency") {
        check.test("is valued in the plan's currency with no fee") {
            // EGP 5,000 counted in a wallet: 5,000 / 52.070874 = 96.0230… → $96.02. A fee would have
            // made it $98.90 at 3%, and reconciling would then invent money.
            let value = converter.value(of: 500_000, in: egp, quote: quote)
            check.expect(value, 9_602)
        }

        check.test("keeps a card's owed balance negative") {
            // AED 1,000 owed: 1,000 / 3.6725 = 272.294… → −$272.29.
            check.expect(converter.value(of: -100_000, in: aed, quote: quote), -27_229)
        }

        check.test("reads the currency's own digits") {
            // ¥10,000 has no minor unit: 10,000 / 156.25 = $64.00 exactly.
            check.expect(converter.value(of: 10_000, in: jpy, quote: quote), 6_400)
        }

        check.test("needs no rate for the plan's own currency") {
            check.expect(converter.value(of: 1_234, in: usd, quote: quote), 1_234)
        }

        check.test("says so rather than guessing when the rate is missing") {
            let unknown = CurrencyRegistry.currency(forCode: "XYZ")
            check.expectNil(converter.value(of: 1_000, in: unknown, quote: quote))
        }
    }

    check.suite("Exchange rate providers") {
        check.test("decodes an open.er-api.com response") {
            let json = """
            {"result":"success","base_code":"USD","time_last_update_unix":1790000000,
             "rates":{"USD":1,"EGP":52.070874,"AED":3.6725,"KES":129.549122}}
            """
            let decoded = try OpenExchangeRateAPIProvider.decode(Data(json.utf8))
            check.expect(decoded.baseCode, "USD")
            check.expect(decoded.rates["EGP"], 52.070874)
            check.expect(decoded.asOf, Date(timeIntervalSince1970: 1_790_000_000))
            check.expect(decoded.providerName, "open.er-api.com")
        }

        check.test("surfaces an open.er-api.com error instead of returning empty rates") {
            let json = #"{"result":"error","base_code":"XXX","error-type":"unsupported-code","rates":{}}"#
            check.expectThrows { try OpenExchangeRateAPIProvider.decode(Data(json.utf8)) }
            check.expectThrows { try OpenExchangeRateAPIProvider.decode(Data("not json".utf8)) }
        }

        check.test("decodes a frankfurter.app response and its date") {
            let json = #"{"amount":1.0,"base":"USD","date":"2026-09-28","rates":{"EUR":0.85,"GBP":0.74}}"#
            let decoded = try FrankfurterProvider.decode(Data(json.utf8))
            check.expect(decoded.baseCode, "USD")
            check.expect(decoded.rates["EUR"], 0.85)
            let parts = Calendar.gregorianUTC.dateComponents([.year, .month, .day], from: decoded.asOf)
            check.expect(parts.year, 2026)
            check.expect(parts.month, 9)
            check.expect(parts.day, 28)
            // The reason it is not the default: no EGP, AED, or KES.
            check.expectTrue(!decoded.supports("EGP"))
        }
    }
}
