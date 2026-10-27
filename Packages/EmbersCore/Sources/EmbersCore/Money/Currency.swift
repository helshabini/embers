import Foundation

/// A signed amount expressed in a currency's smallest unit (cents for USD, fils for AED, yen for JPY).
public typealias MinorUnits = Int64

/// An ISO 4217 currency, identified by its alphabetic code.
public struct Currency: Hashable, Sendable, Codable {
    public let code: String
    /// Digits after the decimal separator: 2 for USD, 0 for JPY, 3 for KWD.
    public let minorUnitDigits: Int

    public init(code: String, minorUnitDigits: Int) {
        self.code = code.uppercased()
        self.minorUnitDigits = minorUnitDigits
    }

    /// 10^minorUnitDigits — the number of minor units in one major unit.
    public var minorUnitsPerMajor: Int64 {
        var result: Int64 = 1
        for _ in 0..<minorUnitDigits { result *= 10 }
        return result
    }

    public var localizedName: String? {
        CurrencyRegistry.localizedName(forCode: code)
    }

    /// The short symbol to put next to a figure — "$", not "US$".
    ///
    /// Foundation disambiguates by default, because a British reader seeing "$" cannot tell US from
    /// Australian dollars. In a budget denominated in one currency that ambiguity does not arise, and
    /// the prefix is noise on every row. Falls back to the code where no symbol exists.
    public var symbol: String {
        CurrencyRegistry.symbol(forCode: code)
    }
}

/// Lookup of ISO 4217 currencies.
///
/// Codes and display names come from Foundation. Only the minor-unit exceptions are hardcoded,
/// because Foundation exposes no reliable accessor for them and getting them wrong silently
/// misplaces the decimal point on entry (a 100x error for JPY, 10x for KWD).
public enum CurrencyRegistry {
    private static let zeroDigitCodes: Set<String> = [
        "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG",
        "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF",
    ]
    private static let threeDigitCodes: Set<String> = [
        "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND",
    ]
    private static let fourDigitCodes: Set<String> = ["CLF", "UYW"]

    public static func minorUnitDigits(forCode code: String) -> Int {
        let code = code.uppercased()
        if zeroDigitCodes.contains(code) { return 0 }
        if threeDigitCodes.contains(code) { return 3 }
        if fourDigitCodes.contains(code) { return 4 }
        return 2
    }

    public static func currency(forCode code: String) -> Currency {
        Currency(code: code, minorUnitDigits: minorUnitDigits(forCode: code))
    }

    /// Every ISO 4217 code Foundation knows about, uppercased and sorted.
    public static let allCodes: [String] = Locale.Currency.isoCurrencies
        .map(\.identifier.localizedUppercase)
        .sorted()

    private static let knownCodes = Set(allCodes)

    /// Built once. A currency search filters on these, and asking the locale for all three hundred
    /// on every keystroke was most of what typing in the picker cost.
    private static let localizedNames: [String: String] = Dictionary(
        allCodes.compactMap { code in
            Locale.current.localizedString(forCurrencyCode: code).map { (code, $0) }
        },
        uniquingKeysWith: { first, _ in first }
    )

    public static func localizedName(forCode code: String) -> String? {
        localizedNames[code] ?? Locale.current.localizedString(forCurrencyCode: code)
    }

    public static func isValidCode(_ code: String) -> Bool {
        knownCodes.contains(code.uppercased())
    }

    public static let usd = currency(forCode: "USD")

    private static let symbolLock = NSLock()
    nonisolated(unsafe) private static var symbolCache: [String: String] = [:]

    /// Resolves a currency's short symbol, cached because the lookup builds a locale each time.
    public static func symbol(forCode code: String) -> String {
        let code = code.uppercased()
        symbolLock.lock()
        defer { symbolLock.unlock() }
        if let cached = symbolCache[code] { return cached }

        // Asking a locale that already uses this currency yields its local, unqualified symbol.
        let resolved = Locale(identifier: "en_US@currency=\(code)").currencySymbol
        let symbol: String
        if let resolved, !resolved.isEmpty, resolved != code, resolved.count <= 3 {
            symbol = resolved
        } else {
            symbol = code
        }
        symbolCache[code] = symbol
        return symbol
    }
}
