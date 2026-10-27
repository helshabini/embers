import Foundation
import EmbersCore
import EmbersData
import SwiftData

/// A provider that answers from memory and counts how often it was asked.
private final class CountingProvider: ExchangeRateProvider, @unchecked Sendable {
    let name = OpenExchangeRateAPIProvider.providerName
    let coverageNote = ""
    var publishedAt: Date
    var calls = 0

    init(publishedAt: Date) { self.publishedAt = publishedAt }

    func fetchQuote(base: String) async throws -> ExchangeRateQuote {
        calls += 1
        return ExchangeRateQuote(baseCode: base, asOf: publishedAt, providerName: name, rates: ["EGP": 52.07])
    }
}

/// Runs main-actor async work to completion from the checks' top level, which has no async harness.
@MainActor
private func waitFor<T>(_ work: @escaping @MainActor () async -> T) -> T {
    var result: T?
    Task { @MainActor in result = await work() }
    while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    return result!
}

func fxRefreshChecks(_ check: Checker) {
    let hour: TimeInterval = 60 * 60
    let published = Date(timeIntervalSince1970: 1_790_000_000)

    check.suite("Exchange rate refreshing") {
        check.test("asks only once the provider may have published again") {
            let cached = ExchangeRateQuote(baseCode: "USD", asOf: published, providerName: "p", rates: [:])
            check.expectTrue(ExchangeRateService.shouldFetch(cached: nil, lastAttempt: nil, now: published))
            // The bug: rates fetched a moment ago, published 13 hours before that, counted as stale.
            check.expectTrue(
                !ExchangeRateService.shouldFetch(cached: cached, lastAttempt: nil, now: published + 13 * hour),
                "a day's rates are current until the next day's are out"
            )
            check.expectTrue(ExchangeRateService.shouldFetch(cached: cached, lastAttempt: nil, now: published + 25 * hour))
        }

        check.test("never asks twice within the hour, however stale") {
            check.expectTrue(!ExchangeRateService.shouldFetch(
                cached: nil, lastAttempt: published, now: published + 10 * 60
            ))
            check.expectTrue(ExchangeRateService.shouldFetch(
                cached: nil, lastAttempt: published, now: published + 61 * 60
            ))
        }

        check.test("keeps one copy per publication, and only the last few") {
            // The checks run on the main thread; the refresh is main-actor work, as in the app.
            let seen = try MainActor.assumeIsolated { try refreshScenario(published: published) }
            check.expect(seen.afterFirst, Seen.Step(calls: 1, copies: 1), "an empty cache asks")
            check.expect(seen.sameDay, Seen.Step(calls: 1, copies: 1), "the same day's rates are not asked for again")
            check.expect(seen.providerLate, Seen.Step(calls: 2, copies: 1), "a day on it asks, but the same publication adds nothing")
            check.expect(seen.lateAgain, Seen.Step(calls: 2, copies: 1), "and it is not asked again within the hour")
            check.expect(seen.afterEightDays, Seen.Step(calls: 10, copies: 5), "superseded copies are pruned")
            check.expectTrue(seen.latestIsNewest, "the newest publication is the one in force")
        }

        check.test("credits the provider that asks for it") {
            check.expect(
                ExchangeRateAttribution.forProvider(named: "open.er-api.com")?.text,
                "Rates By Exchange Rate API"
            )
            check.expectNil(ExchangeRateAttribution.forProvider(named: "frankfurter.app"))
        }
    }
}

/// What the store and the provider looked like after each step of `refreshScenario`.
private struct Seen: Sendable {
    struct Step: Equatable, Sendable {
        let calls: Int
        let copies: Int
    }

    var afterFirst = Step(calls: 0, copies: 0)
    var sameDay = Step(calls: 0, copies: 0)
    var providerLate = Step(calls: 0, copies: 0)
    var lateAgain = Step(calls: 0, copies: 0)
    var afterEightDays = Step(calls: 0, copies: 0)
    var latestIsNewest = false
}

/// A week and a bit of refreshing against a real file, run on the main actor as the app runs it.
@MainActor
private func refreshScenario(published: Date) throws -> Seen {
    let hour: TimeInterval = 60 * 60
    let url = URL.temporaryDirectory.appending(path: "fx-\(UUID().uuidString).store")
    let context = ModelContext(try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url))
    let provider = CountingProvider(publishedAt: published)
    let attempts = ExchangeRateService.AttemptLog()
    var seen = Seen()

    func refresh(at now: Date, force: Bool = false) {
        _ = waitFor {
            await ExchangeRateService.refreshIfNeeded(
                baseCode: "USD", provider: provider, in: context, now: now, force: force, attempts: attempts
            )
        }
    }
    func step() throws -> Seen.Step {
        Seen.Step(calls: provider.calls, copies: try context.fetchCount(FetchDescriptor<ExchangeRateSnapshot>()))
    }

    refresh(at: published + hour)
    seen.afterFirst = try step()
    for minutes in [5.0, 30, 120, 600] { refresh(at: published + hour + minutes * 60) }
    seen.sameDay = try step()
    // A day on, the provider is late and still serves yesterday's rates.
    refresh(at: published + 25 * hour)
    seen.providerLate = try step()
    refresh(at: published + 25 * hour + 20 * 60)
    seen.lateAgain = try step()
    // Eight more days of new rates, through the button that asks by name.
    for day in 1...8 {
        provider.publishedAt = published + Double(day) * 24 * hour
        refresh(at: provider.publishedAt + hour, force: true)
    }
    seen.afterEightDays = try step()
    seen.latestIsNewest = try ExchangeRateService.latestQuote(in: context, baseCode: "USD")?.asOf == provider.publishedAt
    return seen
}
