import Foundation

/// The result of entering an amount in one currency and storing it in the plan's base currency.
///
/// Every field is kept so the transaction can explain itself later: what was typed, at what rate,
/// what fee was applied, and what landed in the ledger.
public struct CurrencyConversion: Hashable, Sendable, Codable {
    public var enteredAmount: MinorUnits
    public var enteredCurrencyCode: String
    /// Multiplier applied to get from the entered currency to the base currency.
    public var rateToBase: Double
    public var rateAsOf: Date
    public var rateSource: String
    public var isManualRate: Bool
    /// The bank's foreign-transaction fee, as a percentage (1.5 means 1.5%).
    public var feePercent: Decimal
    /// Base-currency amount before the fee.
    public var convertedBeforeFee: MinorUnits
    /// The fee portion, in base currency.
    public var feeAmount: MinorUnits
    /// What is stored in the ledger: converted amount plus fee.
    public var baseAmount: MinorUnits

    public init(
        enteredAmount: MinorUnits,
        enteredCurrencyCode: String,
        rateToBase: Double,
        rateAsOf: Date,
        rateSource: String,
        isManualRate: Bool,
        feePercent: Decimal,
        convertedBeforeFee: MinorUnits,
        feeAmount: MinorUnits,
        baseAmount: MinorUnits
    ) {
        self.enteredAmount = enteredAmount
        self.enteredCurrencyCode = enteredCurrencyCode
        self.rateToBase = rateToBase
        self.rateAsOf = rateAsOf
        self.rateSource = rateSource
        self.isManualRate = isManualRate
        self.feePercent = feePercent
        self.convertedBeforeFee = convertedBeforeFee
        self.feeAmount = feeAmount
        self.baseAmount = baseAmount
    }

    public var appliedFee: Bool { feePercent != 0 }
}

/// Converts an entered amount into the plan's base currency, applying the bank's foreign-transaction
/// fee when the entered currency differs from the **account's** currency.
///
/// The fee is keyed to the account, not the plan: spending AED on an AED card is a domestic
/// transaction even when the plan is denominated in USD, while spending EGP on that same card is a
/// foreign one and the bank marks it up.
///
///     plan base USD, account AED, enter 200 AED   → no fee   → 200 ÷ 3.6725     = $54.46
///     plan base USD, account AED, enter 1,000 EGP → 1.5% fee → (1000 ÷ 52.07) × 1.015 = $19.49
///     plan base USD, account EGP, enter 100 USD   → 3% fee   → 100 × 1.03       = $103.00
public struct CurrencyConverter: Sendable {
    public let baseCurrency: Currency

    public init(baseCurrency: Currency) {
        self.baseCurrency = baseCurrency
    }

    /// - Parameters:
    ///   - accountCurrency: The account's own currency, which decides whether a fee applies.
    ///   - feePercent: The bank's markup as a percentage. Ignored when no fee applies.
    public func convert(
        enteredAmount: MinorUnits,
        from enteredCurrency: Currency,
        accountCurrency: Currency,
        quote: ExchangeRateQuote,
        feePercent: Decimal,
        manualRate: Double? = nil
    ) throws -> CurrencyConversion {
        let rate: Double
        if let manualRate {
            rate = manualRate
        } else if let quoted = quote.rate(from: enteredCurrency.code, to: baseCurrency.code) {
            rate = quoted
        } else {
            throw ExchangeRateError.unsupportedCurrency(enteredCurrency.code)
        }

        return convert(
            enteredAmount: enteredAmount,
            from: enteredCurrency,
            accountCurrency: accountCurrency,
            rate: rate,
            rateAsOf: manualRate == nil ? quote.asOf : Date(),
            rateSource: manualRate == nil ? quote.providerName : "manual",
            isManualRate: manualRate != nil,
            feePercent: feePercent
        )
    }

    public func convert(
        enteredAmount: MinorUnits,
        from enteredCurrency: Currency,
        accountCurrency: Currency,
        rate: Double,
        rateAsOf: Date,
        rateSource: String,
        isManualRate: Bool,
        feePercent: Decimal
    ) -> CurrencyConversion {
        let effectiveFee = Self.feeApplies(entered: enteredCurrency, account: accountCurrency)
            ? feePercent
            : 0

        let enteredMajor = Decimal(enteredAmount) / Decimal(enteredCurrency.minorUnitsPerMajor)
        let convertedMajor = enteredMajor * Decimal(rate)
        let totalMajor = convertedMajor * (1 + effectiveFee / 100)

        let convertedBeforeFee = Self.round(convertedMajor, to: baseCurrency)
        let baseAmount = Self.round(totalMajor, to: baseCurrency)

        return CurrencyConversion(
            enteredAmount: enteredAmount,
            enteredCurrencyCode: enteredCurrency.code,
            rateToBase: rate,
            rateAsOf: rateAsOf,
            rateSource: rateSource,
            isManualRate: isManualRate,
            feePercent: effectiveFee,
            convertedBeforeFee: convertedBeforeFee,
            // Derived from the rounded endpoints so the parts always sum to the stored total.
            feeAmount: baseAmount - convertedBeforeFee,
            baseAmount: baseAmount
        )
    }

    /// What a balance held in `currency` is worth in the plan's currency, at the quote's rate.
    ///
    /// No fee, ever: a balance is money held, not a purchase the bank converted. Reconciling a wallet
    /// counted in EGP against a USD plan uses this, so nobody has to do the sum by hand.
    ///
    /// - Returns: `nil` when the quote does not carry the currency.
    public func value(
        of amount: MinorUnits,
        in currency: Currency,
        quote: ExchangeRateQuote
    ) -> MinorUnits? {
        guard let rate = quote.rate(from: currency.code, to: baseCurrency.code) else { return nil }
        return convert(
            enteredAmount: amount,
            from: currency,
            accountCurrency: currency,
            rate: rate,
            rateAsOf: quote.asOf,
            rateSource: quote.providerName,
            isManualRate: false,
            feePercent: 0
        ).baseAmount
    }

    /// A fee applies when the amount is charged in a currency the account does not hold.
    public static func feeApplies(entered: Currency, account: Currency) -> Bool {
        entered.code != account.code
    }

    private static func round(_ major: Decimal, to currency: Currency) -> MinorUnits {
        var scaled = major * Decimal(currency.minorUnitsPerMajor)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return MinorUnits(truncating: rounded)
    }
}

extension MinorUnits {
    /// Decimal has no lossless Int64 conversion, so go through NSDecimalNumber.
    fileprivate init(truncating decimal: Decimal) {
        self = (decimal as NSDecimalNumber).int64Value
    }
}
