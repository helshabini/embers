import Foundation
import EmbersCore
import EmbersData
import SwiftData

/// Times the work the app does, against a real budget.
///
/// Guessing which part of a screen is slow is how the wrong thing gets optimised. This loads a
/// backup into a real on-disk store — relationship faults and all, which an in-memory store does not
/// reproduce — and reports where the time actually goes.
@MainActor
func run() async throws {
    let arguments = CommandLine.arguments
    guard arguments.count > 1 else {
        print("usage: benchmark <backup.embers.json> [--repeat n]")
        exit(2)
    }
    let repeats = arguments.firstIndex(of: "--repeat").map { Int(arguments[$0 + 1]) ?? 3 } ?? 3

    let storeURL = URL.temporaryDirectory.appending(path: "benchmark-\(UUID().uuidString).store")
    let container = try EmbersStore.container(cloudKitContainerIdentifier: nil, url: storeURL)
    let context = ModelContext(container)

    let archive = try BackupWriter.decode(Data(contentsOf: URL(filePath: arguments[1])))
    try time("restore backup") { try BackupWriter.restore(archive, into: context) }

    if arguments.contains("--explain") {
        try explainMonths(context, [
            YearMonth(year: 2026, month: 8),
            YearMonth(year: 2026, month: 9),
            YearMonth(year: 2026, month: 10),
        ])
        try? FileManager.default.removeItem(at: storeURL)
        return
    }

    let counts = (
        accounts: try context.fetchCount(FetchDescriptor<Account>()),
        transactions: try context.fetchCount(FetchDescriptor<LedgerTransaction>()),
        categories: try context.fetchCount(FetchDescriptor<BudgetCategoryModel>()),
        assignments: try context.fetchCount(FetchDescriptor<CategoryAssignment>())
    )
    print("""

    budget: \(counts.transactions) transactions, \(counts.accounts) accounts, \
    \(counts.categories) categories, \(counts.assignments) assignments
    """)

    // Each measurement reopens the store, so no measurement is helped by the one before warming
    // SwiftData's caches — which is the state the app is in when a screen first opens.
    for label in ["cold", "warm"] {
        print("\n── \(label) ──")
        func measure(_ name: String, _ body: @MainActor (ModelContext) throws -> Void) throws {
            let ctx = label == "cold"
                ? ModelContext(try EmbersStore.container(cloudKitContainerIdentifier: nil, url: storeURL))
                : context
            try time(name, repeats: label == "cold" ? 1 : repeats) { try body(ctx) }
        }

        try measure("BudgetInputBuilder.build") { _ = try BudgetInputBuilder.build(from: $0) }
        try measure("engine.compute") { ctx in
            let input = try BudgetInputBuilder.build(from: ctx)
            _ = BudgetEngine().compute(input, through: .current())
        }
        try measure("fetch every transaction") { ctx in
            _ = try ctx.fetch(FetchDescriptor<LedgerTransaction>())
        }
        try measure("fetch + read one field each") { ctx in
            let rows = try ctx.fetch(FetchDescriptor<LedgerTransaction>())
            var total = 0
            for row in rows { total += row.amountMinor }
            _ = total
        }
        try measure("fetch + touch account relationship") { ctx in
            let rows = try ctx.fetch(FetchDescriptor<LedgerTransaction>())
            var seen = 0
            for row in rows where row.account != nil { seen += 1 }
            _ = seen
        }
        try measure("fetch + isSplitParent on each") { ctx in
            let rows = try ctx.fetch(FetchDescriptor<LedgerTransaction>())
            var parents = 0
            for row in rows where row.isSplitParent { parents += 1 }
            _ = parents
        }
        try measure("fetch 300 newest (fetchLimit)") { ctx in
            var descriptor = FetchDescriptor<LedgerTransaction>(
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            descriptor.fetchLimit = 300
            _ = try ctx.fetch(descriptor)
        }
        try measure("fetch all, propertiesToFetch") { ctx in
            var descriptor = FetchDescriptor<LedgerTransaction>()
            descriptor.propertiesToFetch = [\.date, \.amountMinor]
            _ = try ctx.fetch(descriptor)
        }
        try measure("fetchCount only") { ctx in
            _ = try ctx.fetchCount(FetchDescriptor<LedgerTransaction>())
        }
        try measure("fetch rows that repeat (scan)") { ctx in
            let asOf = Date.endOfBudgetDay()
            _ = try ctx.fetch(
                FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.date <= asOf })
            ).filter { $0.recurrence != nil }
        }
        try measure("register: busiest account, all") { ctx in
            let accounts = try ctx.fetch(FetchDescriptor<Account>())
            var busiest: (UUID, Int) = (UUID(), 0)
            for account in accounts {
                let id = account.identifier
                let n = try ctx.fetchCount(
                    FetchDescriptor<LedgerTransaction>(
                        predicate: #Predicate { $0.account?.identifier == id && $0.parent == nil }
                    )
                )
                if n > busiest.1 { busiest = (id, n) }
            }
            let id = busiest.0
            _ = try ctx.fetch(
                FetchDescriptor<LedgerTransaction>(
                    predicate: #Predicate { $0.account?.identifier == id && $0.parent == nil },
                    sortBy: [SortDescriptor(\.date, order: .reverse)]
                )
            )
        }
        try measure("transactions page: new shape") { ctx in
            let cutoff = Date.endOfBudgetDay()
            var upcoming = FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.date > cutoff && $0.parent == nil },
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            upcoming.fetchLimit = 300
            _ = try ctx.fetch(upcoming).collapsingTransferPairs()
            var recent = FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.date <= cutoff && $0.parent == nil },
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            recent.fetchLimit = 600
            _ = Array(try ctx.fetch(recent).collapsingTransferPairs().prefix(300))
            _ = try ctx.fetchCount(
                FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.parent == nil })
            )
        }
        try measure("repairUnpairedTransfers") { _ = try TransferWriter.repairUnpairedTransfers(in: $0) }
        try measure("advanceDueOccurrences") {
            _ = try RecurrenceWriter.advanceDueOccurrences(in: $0, asOf: .endOfBudgetDay())
        }
    }

    try? FileManager.default.removeItem(at: storeURL)
}

/// Prints what the engine makes of a month, piece by piece.
@MainActor
func explainMonths(_ context: ModelContext, _ months: [YearMonth]) throws {
    let input = try BudgetInputBuilder.build(from: context)
    let result = BudgetEngine().compute(input, through: months.last ?? .current())
    for month in months {
        guard let state = result.months[month] else { continue }
        print("")
        print("\(month.year)-\(month.month)")
        print("  inflow - assigned (plain)  " + money(state.uncappedReadyToAssign))
        print("  Ready to Assign (shown)    " + money(state.readyToAssign))
        print("  on-budget accounts hold    " + money(state.onBudgetFunds))
        print("  envelopes hold (positive)  " + money(state.envelopesHold))
        print("  cash overspending          " + money(state.cashOverspending))
        print("  credit overspending        " + money(state.creditOverspending))
    }
}

func money(_ minor: MinorUnits) -> String {
    Money(minorUnits: minor, currency: CurrencyRegistry.usd).formatted()
}

@MainActor
func time(_ name: String, repeats: Int = 1, _ body: @MainActor () throws -> Void) rethrows {
    var best = Double.greatestFiniteMagnitude
    var total = 0.0
    for _ in 0..<repeats {
        let start = ContinuousClock.now
        try body()
        let elapsed = Double(start.duration(to: .now).components.attoseconds) / 1e18
            + Double(start.duration(to: .now).components.seconds)
        best = min(best, elapsed)
        total += elapsed
    }
    let mean = total / Double(repeats)
    print(String(format: "  %-34s best %7.1f ms   mean %7.1f ms", (name as NSString).utf8String!, best * 1000, mean * 1000))
}

try await run()
