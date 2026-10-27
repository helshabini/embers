import Foundation

public enum ExchangeRateError: Error, CustomStringConvertible, Equatable {
    case badResponse(status: Int)
    case malformedPayload(String)
    case providerReportedFailure(String)
    case unsupportedCurrency(String)
    case noRatesAvailable

    public var description: String {
        switch self {
        case let .badResponse(status): String(localized: "The rate service returned HTTP \(status).", bundle: .module, locale: .display)
        case let .malformedPayload(detail): String(localized: "The rate service returned unexpected data: \(detail).", bundle: .module)
        case let .providerReportedFailure(detail): String(localized: "The rate service reported an error: \(detail).", bundle: .module)
        case let .unsupportedCurrency(code): String(localized: "No rate is available for \(code).", bundle: .module)
        case .noRatesAvailable: String(localized: "No exchange rates are available yet.", bundle: .module)
        }
    }
}

/// The credit a provider asks for wherever its rates are shown.
public struct ExchangeRateAttribution: Sendable, Equatable {
    /// The link's wording, as the provider asks for it. Not translated: it is their requirement.
    public let text: String
    public let url: URL

    /// The credit owed for rates from the provider named on a quote, if any.
    public static func forProvider(named name: String) -> ExchangeRateAttribution? {
        switch name {
        case OpenExchangeRateAPIProvider.providerName: OpenExchangeRateAPIProvider.attribution
        default: nil
        }
    }
}

public protocol ExchangeRateProvider: Sendable {
    var name: String { get }
    /// Currencies the provider covers, for showing the user why a code is unavailable.
    var coverageNote: String { get }
    func fetchQuote(base: String) async throws -> ExchangeRateQuote
}

/// Fetches from open.er-api.com: free, no API key, ~160 currencies, updated daily.
///
/// This is the default because it covers the currencies this app is used with — EGP, AED, KES — which
/// the ECB reference set behind Frankfurter does not.
public struct OpenExchangeRateAPIProvider: ExchangeRateProvider {
    public static let providerName = "open.er-api.com"
    public let name = Self.providerName

    /// Their open endpoint's terms: "We require attribution on the pages you're using these rates
    /// with", as a link reading exactly this.
    public static let attribution = ExchangeRateAttribution(
        text: "Rates By Exchange Rate API",
        url: URL(string: "https://www.exchangerate-api.com")!
    )
    public var coverageNote: String {
        String(localized: "About 160 currencies, updated daily.", bundle: .module)
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchQuote(base: String) async throws -> ExchangeRateQuote {
        let base = base.uppercased()
        guard let url = URL(string: "https://open.er-api.com/v6/latest/\(base)") else {
            throw ExchangeRateError.malformedPayload("invalid URL for base \(base)")
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ExchangeRateError.badResponse(status: http.statusCode)
        }
        return try Self.decode(data, providerName: name)
    }

    struct Payload: Decodable {
        let result: String
        let base_code: String
        let time_last_update_unix: Double?
        let rates: [String: Double]
        let `error-type`: String?
    }

    public static func decode(_ data: Data, providerName: String = "open.er-api.com") throws -> ExchangeRateQuote {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ExchangeRateError.malformedPayload("\(error)")
        }
        guard payload.result == "success" else {
            throw ExchangeRateError.providerReportedFailure(payload.`error-type` ?? payload.result)
        }
        guard !payload.rates.isEmpty else { throw ExchangeRateError.noRatesAvailable }
        return ExchangeRateQuote(
            baseCode: payload.base_code,
            asOf: payload.time_last_update_unix.map { Date(timeIntervalSince1970: $0) } ?? Date(),
            providerName: providerName,
            rates: payload.rates
        )
    }
}

/// Fetches from frankfurter.app, which serves ECB reference rates.
///
/// Offered as an alternative, with the caveat that the ECB set is only ~30 currencies and excludes
/// EGP, AED, and KES.
public struct FrankfurterProvider: ExchangeRateProvider {
    public let name = "frankfurter.app"
    public var coverageNote: String {
        String(localized: "About 30 ECB currencies. Excludes EGP, AED, and KES.", bundle: .module)
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchQuote(base: String) async throws -> ExchangeRateQuote {
        let base = base.uppercased()
        guard let url = URL(string: "https://api.frankfurter.app/latest?base=\(base)") else {
            throw ExchangeRateError.malformedPayload("invalid URL for base \(base)")
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ExchangeRateError.badResponse(status: http.statusCode)
        }
        return try Self.decode(data, providerName: name)
    }

    struct Payload: Decodable {
        let base: String
        let date: String
        let rates: [String: Double]
    }

    public static func decode(_ data: Data, providerName: String = "frankfurter.app") throws -> ExchangeRateQuote {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ExchangeRateError.malformedPayload("\(error)")
        }
        guard !payload.rates.isEmpty else { throw ExchangeRateError.noRatesAvailable }
        let parts = payload.date.split(separator: "-").compactMap { Int($0) }
        let asOf = parts.count == 3
            ? Calendar.gregorianUTC.date(
                from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
            ) ?? Date()
            : Date()
        return ExchangeRateQuote(
            baseCode: payload.base,
            asOf: asOf,
            providerName: providerName,
            rates: payload.rates
        )
    }
}
