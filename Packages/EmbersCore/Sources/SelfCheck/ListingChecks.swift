import Foundation
import EmbersCore
import EmbersData
import SwiftData

/// Showing only the newest few hundred entries, without that changing what they say.
///
/// The all-accounts list used to read every transaction in the budget on every open. It reads a page
/// now, which is twenty-seven times faster and introduces a boundary that did not exist before: the
/// two halves of a transfer can fall either side of it. These pin what a page is allowed to do.
@MainActor
func listingChecks(_ check: Checker) {
    let cutoff = Date.budgetDay(year: 2026, month: 10, day: 1)

    @MainActor func store() throws -> (ModelContext, Account, Account) {
        let context = ModelContext(try EmbersStore.inMemoryContainer())
        let checking = Account(name: "Checking", type: .checking)
        let savings = Account(name: "Savings", type: .savings)
        context.insert(checking)
        context.insert(savings)
        return (context, checking, savings)
    }

    check.suite("A page of transactions") {
        check.test("shows each transfer once, and every other entry too") {
            let (context, checking, savings) = try store()
            for day in 1...5 {
                context.insert(
                    LedgerTransaction(
                        date: .budgetDay(year: 2026, month: 9, day: day),
                        amountMinor: -1_000, account: checking
                    )
                )
                TransferWriter.makeTransfer(
                    amountMinor: 5_000, from: checking, to: savings,
                    date: .budgetDay(year: 2026, month: 9, day: day), in: context
                )
            }
            try context.save()

            let all = try context.fetch(FetchDescriptor<LedgerTransaction>())
            check.expect(all.count, 15, "five plain entries and five transfers, two rows each")
            let shown = all.collapsingTransferPairs()
            check.expect(shown.count, 10, "five plain entries and five transfers, one row each")
            check.expect(
                shown.filter(\.isTransfer).count, 5,
                "each transfer stands for its pair"
            )
            check.expectTrue(
                shown.filter(\.isTransfer).allSatisfy { $0.amountMinor < 0 },
                "the side kept is the one money left, which is the side with the category"
            )
        }

        check.test("keeps a transfer whose other half is off the page") {
            let (context, checking, savings) = try store()
            let sides = TransferWriter.makeTransfer(
                amountMinor: 5_000, from: checking, to: savings,
                date: .budgetDay(year: 2026, month: 9, day: 1), in: context
            )
            try context.save()

            // What a page boundary looks like: one half is in the window, the other is not.
            let page = [sides.incoming].collapsingTransferPairs()
            check.expect(
                page.count, 1,
                "a half-pair must still be shown, or money disappears from the list"
            )
            check.expect(page.first?.identifier, sides.incoming.identifier)
        }

        check.test("an unpaired transfer is shown, not hidden") {
            let (context, checking, savings) = try store()
            let lonely = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 9, day: 1), amountMinor: -5_000,
                account: checking, transferCounterAccount: savings
            )
            context.insert(lonely)
            try context.save()

            let shown = try context.fetch(FetchDescriptor<LedgerTransaction>()).collapsingTransferPairs()
            check.expect(shown.count, 1)
        }

        check.test("the line between happened and scheduled falls on the right side of today") {
            let (context, checking, _) = try store()
            for (day, month) in [(30, 9), (1, 10), (2, 10)] {
                context.insert(
                    LedgerTransaction(
                        date: .budgetDay(year: 2026, month: month, day: day),
                        amountMinor: -1_000, account: checking
                    )
                )
            }
            try context.save()

            let all = try context.fetch(FetchDescriptor<LedgerTransaction>())
            let split = all.splitBySchedule(after: .endOfBudgetDay(containing: cutoff, in: .gmt))
            check.expect(split.settled.count, 2, "yesterday and today have happened")
            check.expect(split.scheduled.count, 1, "tomorrow has not")
        }

        /// The page must be the same rows the unbounded list would have started with.
        check.test("a page is the top of the whole list, not a different list") {
            let (context, checking, savings) = try store()
            for day in 1...20 {
                context.insert(
                    LedgerTransaction(
                        date: .budgetDay(year: 2026, month: 9, day: day),
                        amountMinor: -day * 100, account: checking
                    )
                )
                if day % 4 == 0 {
                    TransferWriter.makeTransfer(
                        amountMinor: 5_000, from: checking, to: savings,
                        date: .budgetDay(year: 2026, month: 9, day: day), in: context
                    )
                }
            }
            try context.save()

            let sort = [SortDescriptor(\LedgerTransaction.date, order: SortOrder.reverse)]
            let everything = try context.fetch(FetchDescriptor<LedgerTransaction>(sortBy: sort))
                .collapsingTransferPairs()

            var paged = FetchDescriptor<LedgerTransaction>(sortBy: sort)
            paged.fetchLimit = 12
            let page = try context.fetch(paged).collapsingTransferPairs()

            check.expectTrue(page.count <= 12, "a page does not grow")
            check.expectTrue(!page.isEmpty, "nor is it empty")
            // Dates are what the reader sees ordered; identifiers can differ where a pair straddles.
            let headDates = everything.prefix(page.count).map(\.date)
            check.expect(
                page.map(\.date), headDates,
                "the newest page should be the newest entries, in the same order"
            )
        }

        check.test("a day's entries list the latest entered first, on disk and through a backup") {
            let url = URL.temporaryDirectory.appending(path: "listing-\(UUID().uuidString).store")
            let day = Date.budgetDay(year: 2026, month: 9, day: 30)
            let entered = Date(timeIntervalSince1970: 1_790_000_000)
            do {
                let context = ModelContext(
                    try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url)
                )
                let checking = Account(name: "Checking", type: .checking)
                context.insert(checking)
                // Inserted out of entry order, so the store's own order cannot pass for the rule.
                for (memo, offset) in [("second", 60.0), ("third", 120.0), ("first", 0.0)] {
                    let row = LedgerTransaction(date: day, amountMinor: -100, memo: memo, account: checking)
                    row.createdAt = entered.addingTimeInterval(offset)
                    context.insert(row)
                }
                context.insert(
                    LedgerTransaction(
                        date: .budgetDay(year: 2026, month: 9, day: 29), amountMinor: -100,
                        memo: "yesterday", account: checking
                    )
                )
                try context.save()
            }
            let reopened = ModelContext(
                try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url)
            )
            let listed = try reopened.fetch(
                FetchDescriptor<LedgerTransaction>(sortBy: LedgerTransaction.newestFirst)
            )
            check.expect(listed.map(\.memo), ["third", "second", "first", "yesterday"])

            let restored = ModelContext(try EmbersStore.inMemoryContainer())
            try BackupWriter.restore(
                try BackupWriter.decode(try BackupWriter.data(from: reopened)), into: restored
            )
            check.expect(
                try restored.fetch(
                    FetchDescriptor<LedgerTransaction>(sortBy: LedgerTransaction.newestFirst)
                ).map(\.memo),
                ["third", "second", "first", "yesterday"],
                "a restore must not reset every entry to the moment it was restored"
            )
        }

        check.test("a backup with no entry times keeps its own order") {
            let source = ModelContext(try EmbersStore.inMemoryContainer())
            let checking = Account(name: "Checking", type: .checking)
            source.insert(checking)
            for memo in ["first", "second", "third"] {
                source.insert(
                    LedgerTransaction(
                        date: .budgetDay(year: 2026, month: 9, day: 30), amountMinor: -100,
                        memo: memo, account: checking
                    )
                )
            }
            try source.save()
            // What a backup written before entry times were kept looks like: the same rows, in the
            // order they were entered, and no times.
            var json = try JSONSerialization.jsonObject(
                with: try BackupWriter.data(from: source)
            ) as? [String: Any] ?? [:]
            let rows = (json["transactions"] as? [[String: Any]] ?? [])
                .map { row in row.filter { $0.key != "createdAt" } }
            let order = ["first", "second", "third"]
            json["transactions"] = rows.sorted {
                order.firstIndex(of: $0["memo"] as? String ?? "")!
                    < order.firstIndex(of: $1["memo"] as? String ?? "")!
            }
            let archive = try BackupWriter.decode(try JSONSerialization.data(withJSONObject: json))

            let restored = ModelContext(try EmbersStore.inMemoryContainer())
            try BackupWriter.restore(archive, into: restored)
            check.expect(
                try restored.fetch(
                    FetchDescriptor<LedgerTransaction>(sortBy: LedgerTransaction.newestFirst)
                ).map(\.memo),
                ["third", "second", "first"]
            )
        }

        check.test("a deleted row says so instead of being read") {
            let url = URL.temporaryDirectory.appending(path: "deleted-\(UUID().uuidString).store")
            let context = ModelContext(
                try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url)
            )
            let (checking, savings) = (
                Account(name: "Checking", type: .checking), Account(name: "Savings", type: .savings)
            )
            context.insert(checking)
            context.insert(savings)
            let sides = TransferWriter.makeTransfer(
                amountMinor: 5_000, from: checking, to: savings,
                date: .budgetDay(year: 2026, month: 9, day: 1), in: context
            )
            try context.save()
            check.expectTrue(sides.outgoing.isLive && sides.incoming.isLive)
            try TransactionWriter.delete(sides.outgoing, in: context)
            check.expectTrue(!sides.outgoing.isLive, "the row deleted")
            check.expectTrue(!sides.incoming.isLive, "and the other side of its transfer")
        }
    }
}
