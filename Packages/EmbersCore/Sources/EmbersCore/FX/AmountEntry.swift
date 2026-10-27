import Foundation

/// The state behind the amount keypad, including the multi-currency panel.
///
/// This is a plain value type rather than view state so the arithmetic that decides what gets stored —
/// which currency was typed, whether the bank's fee applies, which rate was used and how stale it is —
/// can be checked without running the app.
///
/// Digits are entered in minor units, the way a banking keypad works: typing `1`, `2`, `3`, `4` with a
/// two-decimal currency reads as 12.34.
public struct AmountEntry: Sendable, Equatable {
    /// The plan's currency. Everything is stored in this.
    public var baseCurrency: Currency
    /// The account's currency, which decides whether the bank charges a foreign-transaction fee.
    public var accountCurrency: Currency
    /// The currency being typed. Defaults to the account's.
    public var enteredCurrency: Currency
    /// The bank's fee for a foreign charge on this account, as a percentage.
    public var feePercent: Decimal
    public var isOutflow: Bool
    /// Overrides the quoted rate, for when the bank used a different one.
    public var manualRate: Double?
    public var quote: ExchangeRateQuote?

    private var digits: String = ""

    public init(
        baseCurrency: Currency,
        accountCurrency: Currency,
        enteredCurrency: Currency? = nil,
        feePercent: Decimal = 0,
        isOutflow: Bool = true,
        quote: ExchangeRateQuote? = nil
    ) {
        self.baseCurrency = baseCurrency
        self.accountCurrency = accountCurrency
        self.enteredCurrency = enteredCurrency ?? accountCurrency
        self.feePercent = feePercent
        self.isOutflow = isOutflow
        self.quote = quote
    }

    // MARK: - Keypad

    public var digitText: String { digits }

    public mutating func append(digit: Character) {
        guard digit.isNumber else { return }
        // Cap the magnitude so a stuck key cannot overflow the ledger.
        guard digits.count < 15 else { return }
        if digits.isEmpty, digit == "0" { return }
        digits.append(digit)
    }

    public mutating func deleteLastDigit() {
        guard !digits.isEmpty else { return }
        digits.removeLast()
    }

    public mutating func clear() {
        digits = ""
    }

    public mutating func toggleDirection() {
        isOutflow.toggle()
    }

    /// Replaces the typed value, for editing an existing transaction.
    public mutating func setEnteredAmount(_ minorUnits: MinorUnits) {
        digits = String(abs(minorUnits))
        if digits == "0" { digits = "" }
    }

    // MARK: - Derived values

    /// The unsigned amount as typed, in the entered currency's minor units.
    public var enteredAmount: MinorUnits {
        MinorUnits(digits) ?? 0
    }

    public var enteredMoney: Money {
        Money(minorUnits: enteredAmount, currency: enteredCurrency)
    }

    public var isEmpty: Bool { digits.isEmpty }

    /// True when the typed currency differs from the account's, so the bank marks the charge up.
    public var feeApplies: Bool {
        CurrencyConverter.feeApplies(entered: enteredCurrency, account: accountCurrency)
    }

    public var effectiveFeePercent: Decimal {
        feeApplies ? feePercent : 0
    }

    /// True when the entered currency is the plan's, so no conversion is needed at all.
    public var isPlainBaseCurrencyEntry: Bool {
        enteredCurrency.code == baseCurrency.code && !feeApplies
    }

    public var rate: Double? {
        if let manualRate { return manualRate }
        // Typing the plan's own currency needs no rate, so entry must not depend on having one
        // cached — otherwise a first launch with no network would store nothing.
        if enteredCurrency.code == baseCurrency.code { return 1 }
        return quote?.rate(from: enteredCurrency.code, to: baseCurrency.code)
    }

    /// True when a rate is needed but none is available, so the entry cannot be completed.
    public var isMissingRate: Bool {
        enteredCurrency.code != baseCurrency.code && rate == nil
    }

    /// How old the quoted rate is, for warning that an offline rate is getting stale.
    public func rateAgeInDays(asOf now: Date = Date()) -> Int? {
        guard manualRate == nil, enteredCurrency.code != baseCurrency.code, let quote else { return nil }
        return quote.ageInDays(asOf: now)
    }

    /// The conversion to store, or nil when a rate is required but unavailable.
    public func conversion() -> CurrencyConversion? {
        guard let rate else { return nil }
        let converter = CurrencyConverter(baseCurrency: baseCurrency)
        return converter.convert(
            enteredAmount: enteredAmount,
            from: enteredCurrency,
            accountCurrency: accountCurrency,
            rate: rate,
            rateAsOf: manualRate == nil ? (quote?.asOf ?? Date()) : Date(),
            rateSource: manualRate == nil ? (quote?.providerName ?? "unknown") : "manual",
            isManualRate: manualRate != nil,
            feePercent: feePercent
        )
    }

    /// The signed amount that would be written to the ledger, in the plan's currency.
    public var signedBaseAmount: MinorUnits {
        let magnitude = conversion()?.baseAmount ?? 0
        return isOutflow ? -magnitude : magnitude
    }

    public var baseMoney: Money {
        Money(minorUnits: signedBaseAmount, currency: baseCurrency)
    }

    /// The fee portion of the stored amount, for showing the breakdown.
    public var feeMoney: Money? {
        guard let conversion = conversion(), conversion.appliedFee else { return nil }
        return Money(minorUnits: conversion.feeAmount, currency: baseCurrency)
    }

    /// Currencies to offer first: the account's, the plan's, then recent ones.
    public func suggestedCurrencyCodes(recent: [String] = []) -> [String] {
        var codes: [String] = [accountCurrency.code, baseCurrency.code]
        for code in recent where !codes.contains(code) {
            codes.append(code)
        }
        return codes
    }
}
