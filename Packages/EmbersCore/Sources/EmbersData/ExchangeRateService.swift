import Foundation
import EmbersCore
import SwiftData

/// Keeps exchange rates available, including offline.
///
/// Rates are cached in the store rather than fetched on demand, because entering an amount while
/// travelling is exactly when the network is least likely to be there. A stale rate with its age shown
/// is more useful than no rate at all, and the entry screen can always be overridden by hand.
public enum ExchangeRateService {
    /// How often the providers publish: once a day.
    public static let publishInterval: TimeInterval = 60 * 60 * 24

    /// The fewest seconds between two attempts on one device, whatever the cache says. The service
    /// limits each address, and says once an hour is never limited.
    public static let minimumAttemptSpacing: TimeInterval = 60 * 60

    public static func latestQuote(in context: ModelContext, baseCode: String) throws -> ExchangeRateQuote? {
        var descriptor = FetchDescriptor<ExchangeRateSnapshot>(
            predicate: #Predicate { $0.baseCode == baseCode },
            sortBy: [SortDescriptor(\.asOf, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.quote
    }

    /// Whether asking the provider could bring anything new.
    ///
    /// Measured from when the rates were *published*, not when they were fetched, and against the
    /// publishing interval. It used to be twelve hours from publication: rates are a day old by the
    /// time the next ones come out, so for half of every day a quote fetched a moment ago already
    /// counted as stale, and every editor that opened fetched again — and saved another copy, which
    /// synced to every device.
    public static func shouldFetch(cached: ExchangeRateQuote?, lastAttempt: Date?, now: Date) -> Bool {
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < minimumAttemptSpacing { return false }
        guard let cached else { return true }
        return now.timeIntervalSince(cached.asOf) >= publishInterval
    }

    /// When this device last asked, per base currency. In memory: a relaunch may ask once more,
    /// which the hour between attempts allows for.
    @MainActor
    public final class AttemptLog {
        public static let shared = AttemptLog()
        var last: [String: Date] = [:]
        public init() {}
    }

    /// Fetches only when the provider may have published since the cached rates, and not more than
    /// once an hour; `force` skips both, for the button that asks for it by name.
    ///
    /// Returns the quote now in force, cached or fresh. A failed fetch is not an error the caller needs
    /// to handle: the cached rates stay usable, so it returns them instead of throwing.
    ///
    /// Main-actor bound because `ModelContext` is not `Sendable`; only the network call suspends.
    @MainActor
    @discardableResult
    public static func refreshIfNeeded(
        baseCode: String,
        provider: any ExchangeRateProvider = OpenExchangeRateAPIProvider(),
        in context: ModelContext,
        now: Date = Date(),
        force: Bool = false,
        attempts: AttemptLog = .shared
    ) async -> ExchangeRateQuote? {
        let cached = try? latestQuote(in: context, baseCode: baseCode)
        guard force || shouldFetch(cached: cached, lastAttempt: attempts.last[baseCode], now: now) else {
            return cached
        }
        attempts.last[baseCode] = now

        do {
            let fresh = try await provider.fetchQuote(base: baseCode)
            // The same publication again — the provider had not updated yet — is not a new copy.
            // Every copy is a row that syncs to every device.
            if let cached, fresh.asOf <= cached.asOf { return cached }
            context.insert(ExchangeRateSnapshot(quote: fresh))
            try? context.save()
            try? pruneSnapshots(in: context)
            return fresh
        } catch {
            return cached
        }
    }

    /// Removes superseded snapshots, keeping the most recent few for offline use.
    public static func pruneSnapshots(in context: ModelContext, keeping count: Int = 5) throws {
        let snapshots = try context.fetch(
            FetchDescriptor<ExchangeRateSnapshot>(sortBy: [SortDescriptor(\.asOf, order: .reverse)])
        )
        for snapshot in snapshots.dropFirst(count) {
            context.delete(snapshot)
        }
        try context.save()
    }
}
