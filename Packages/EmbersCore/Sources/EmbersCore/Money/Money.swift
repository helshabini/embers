import Foundation

/// An exact amount of a specific currency, held as minor units so arithmetic never drifts.
public struct Money: Hashable, Sendable, Codable {
    public var minorUnits: MinorUnits
    public var currency: Currency

    public init(minorUnits: MinorUnits, currency: Currency) {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    public static func zero(_ currency: Currency) -> Money {
        Money(minorUnits: 0, currency: currency)
    }

    public var isNegative: Bool { minorUnits < 0 }
    public var isZero: Bool { minorUnits == 0 }
    public var magnitude: Money { Money(minorUnits: abs(minorUnits), currency: currency) }

    /// Lossy: only for display, charting, and rate math — never to store a balance.
    public var doubleValue: Double {
        Double(minorUnits) / Double(currency.minorUnitsPerMajor)
    }

    public var decimalValue: Decimal {
        Decimal(minorUnits) / Decimal(currency.minorUnitsPerMajor)
    }
}

extension Money: CustomStringConvertible {
    public var description: String { formatted() }

    public func formatted(locale: Locale = .display, showCurrencySymbol: Bool = true) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = showCurrencySymbol ? .currency : .decimal
        formatter.currencyCode = currency.code
        if showCurrencySymbol {
            // Otherwise a non-US locale renders USD as "US$", which is noise on every row.
            formatter.currencySymbol = currency.symbol
        }
        formatter.minimumFractionDigits = currency.minorUnitDigits
        formatter.maximumFractionDigits = currency.minorUnitDigits
        return formatter.string(from: decimalValue as NSDecimalNumber)
            ?? "\(currency.code) \(decimalValue)"
    }
}

// MARK: - Arithmetic

extension Money {
    /// Adding mismatched currencies is a programming error, not a runtime condition to recover from.
    public static func + (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currency == rhs.currency, "Cannot add \(lhs.currency.code) to \(rhs.currency.code)")
        return Money(minorUnits: lhs.minorUnits + rhs.minorUnits, currency: lhs.currency)
    }

    public static func - (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currency == rhs.currency, "Cannot subtract \(rhs.currency.code) from \(lhs.currency.code)")
        return Money(minorUnits: lhs.minorUnits - rhs.minorUnits, currency: lhs.currency)
    }

    public static prefix func - (value: Money) -> Money {
        Money(minorUnits: -value.minorUnits, currency: value.currency)
    }

    public static func += (lhs: inout Money, rhs: Money) { lhs = lhs + rhs }
    public static func -= (lhs: inout Money, rhs: Money) { lhs = lhs - rhs }
}

extension Money: Comparable {
    public static func < (lhs: Money, rhs: Money) -> Bool {
        precondition(lhs.currency == rhs.currency, "Cannot compare \(lhs.currency.code) with \(rhs.currency.code)")
        return lhs.minorUnits < rhs.minorUnits
    }
}

// MARK: - Parsing

extension Money {
    /// Parses a decimal string in major units into minor units, rounding half-up away from zero.
    ///
    /// Accepts an optional leading currency symbol, grouping separators, a leading or trailing
    /// minus, and parenthesised negatives. Returns nil when no digits are present.
    public static func parse(_ text: String, currency: Currency) -> Money? {
        var scalar = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scalar.isEmpty else { return nil }

        var isNegative = false
        if scalar.hasPrefix("(") && scalar.hasSuffix(")") {
            isNegative = true
            scalar = String(scalar.dropFirst().dropLast())
        }
        if scalar.hasSuffix("-") {
            isNegative = true
            scalar = String(scalar.dropLast())
        }

        var digits = ""
        var fractionDigits: String?
        for character in scalar {
            switch character {
            case "-":
                isNegative = true
            case "0"..."9":
                if fractionDigits == nil { digits.append(character) } else { fractionDigits?.append(character) }
            case ".":
                // A second separator means the earlier one was grouping, not decimal.
                if let existing = fractionDigits {
                    digits += existing
                }
                fractionDigits = ""
            default:
                continue  // currency symbols, spaces, grouping separators
            }
        }

        guard !digits.isEmpty || !(fractionDigits ?? "").isEmpty else { return nil }

        let scale = currency.minorUnitDigits
        var fraction = fractionDigits ?? ""
        var roundUp = false
        if fraction.count > scale {
            let keepIndex = fraction.index(fraction.startIndex, offsetBy: scale)
            let firstDropped = fraction[keepIndex]
            roundUp = firstDropped >= "5"
            fraction = String(fraction[fraction.startIndex..<keepIndex])
        } else {
            fraction += String(repeating: "0", count: scale - fraction.count)
        }

        guard let whole = Int64(digits.isEmpty ? "0" : digits),
              let fractionValue = Int64(fraction.isEmpty ? "0" : fraction)
        else { return nil }

        var minor = whole * currency.minorUnitsPerMajor + fractionValue
        if roundUp { minor += 1 }
        return Money(minorUnits: isNegative ? -minor : minor, currency: currency)
    }
}
