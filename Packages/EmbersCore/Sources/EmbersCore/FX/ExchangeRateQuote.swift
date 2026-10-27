import Foundation

/// A set of exchange rates captured at one moment, expressed as units of each currency per one unit
/// of `baseCode`.
public struct ExchangeRateQuote: Hashable, Sendable, Codable {
    public let baseCode: String
    public let asOf: Date
    public let providerName: String
    /// Currency code → units of that currency per one unit of the base.
    public let rates: [String: Double]

    public init(baseCode: String, asOf: Date, providerName: String, rates: [String: Double]) {
        self.baseCode = baseCode.uppercased()
        self.asOf = asOf
        self.providerName = providerName
        self.rates = rates
    }

    /// Multiplier that turns an amount in `source` into an amount in `target`.
    ///
    /// Rates are quoted against the base, so a pair that does not involve the base is crossed through
    /// it: EGP → AED becomes (1 / rate(EGP)) × rate(AED).
    public func rate(from source: String, to target: String) -> Double? {
        let source = source.uppercased()
        let target = target.uppercased()
        if source == target { return 1 }

        let perBase: (String) -> Double? = { code in
            code == baseCode ? 1 : rates[code]
        }
        guard let sourcePerBase = perBase(source), let targetPerBase = perBase(target),
              sourcePerBase != 0
        else { return nil }
        return targetPerBase / sourcePerBase
    }

    public func supports(_ code: String) -> Bool {
        let code = code.uppercased()
        return code == baseCode || rates[code] != nil
    }

    public var currencyCodes: [String] {
        ([baseCode] + rates.keys).sorted()
    }

    /// Whole days between the quote and `now`, used to warn when an offline rate is getting old.
    public func ageInDays(asOf now: Date = Date()) -> Int {
        let days = Calendar.gregorianUTC.dateComponents([.day], from: asOf, to: now).day ?? 0
        return max(0, days)
    }
}
