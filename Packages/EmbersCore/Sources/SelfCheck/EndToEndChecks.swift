import Foundation
import EmbersCore
import EmbersData
import SwiftData

/// Runs the whole import path the app will run: read the zip, commit to a store, read it back, and
/// compare the closing month against the figures YNAB itself reported.
///
/// Skipped when the export is not on this machine, since it is the only sample of YNAB's real output.
@MainActor
func endToEndChecks(_ check: Checker) {
    let url = URL(fileURLWithPath: NSString(
        string: "~/Downloads/YNAB Export - My Budget as of 2026-09-29 19-50.zip"
    ).expandingTildeInPath)

    check.suite("Importing the real export end to end") {
        guard FileManager.default.fileExists(atPath: url.path) else {
            check.test("the real export is present") {
                print("      (skipped: export not on this machine)")
            }
            return
        }

        check.test("reads the export's own timestamp from the archive") {
            let budget = try YNABImport.read(archiveAt: url)
            let exportedAt = try check.unwrap(budget.report.sourceExportedAt)
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: exportedAt)
            check.expect(parts.year, 2026)
            check.expect(parts.month, 9)
            check.expect(parts.day, 29)
        }

        check.test("refuses to import over a budget that already holds data") {
            let container = try EmbersStore.inMemoryContainer()
            let context = ModelContext(container)
            let budget = try YNABImport.read(archiveAt: url)
            try YNABImport.commit(budget, into: context)
            check.expectThrows("second import without replaceExisting") {
                try YNABImport.commit(budget, into: context)
            }
        }

        check.test("lands the closing month on exactly the balances YNAB reported") {
            let container = try EmbersStore.inMemoryContainer()
            let context = ModelContext(container)
            let budget = try YNABImport.read(archiveAt: url)
            let outcome = try YNABImport.commit(budget, into: context)

            // Nothing to adjust. Two card categories once needed −$55.36 between them, until a card
            // in credit stopped holding cash set aside for a payment that would never come.
            let reconciliation = try check.unwrap(outcome.reconciliation)
            check.expect(reconciliation.adjustments.count, 0)
            check.expect(reconciliation.totalAmount, 0)

            let closingMonth = try check.unwrap(budget.report.lastMonth)
            let cutoff = YNABImport.reconciliationCutoff(
                exportedAt: budget.report.sourceExportedAt,
                closingMonth: closingMonth
            )
            let input = try BudgetInputBuilder.build(from: context)
            let result = BudgetEngine().compute(input, asOf: cutoff, through: closingMonth)

            var mismatched: [String] = []
            for expectation in budget.expectations where expectation.month == closingMonth {
                guard let categoryID = expectation.categoryID else { continue }
                let available = result.state(of: categoryID, in: closingMonth).available
                if available != expectation.available {
                    mismatched.append(
                        "\(expectation.categoryName): expected \(expectation.available), got \(available)"
                    )
                }
            }
            check.expect(mismatched.count, 0, mismatched.joined(separator: "; "))
        }

        check.test("stores every account, payee and transaction from the export") {
            let container = try EmbersStore.inMemoryContainer()
            let context = ModelContext(container)
            let budget = try YNABImport.read(archiveAt: url)
            try YNABImport.commit(budget, into: context)

            check.expect(try context.fetchCount(FetchDescriptor<Account>()), 32)
            check.expect(try context.fetchCount(FetchDescriptor<Payee>()), 580)
            // 10,754 parents plus 68 split lines.
            check.expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 10_822)
            check.expect(try context.fetchCount(FetchDescriptor<CategoryGroup>()), 9)
            check.expect(try context.fetchCount(FetchDescriptor<BudgetCategoryModel>()), 61)

            let accounts = try context.fetch(FetchDescriptor<Account>())
            let cards = accounts.filter { $0.type == .creditCard }
            check.expect(cards.count, 5)
            check.expect(cards.filter(\.closed).count, 3)

            // Account currencies come from the name suffixes, where they are real ISO codes.
            let currencies = Set(accounts.map(\.currencyCode))
            check.expectTrue(currencies.contains("EGP"), "EGP accounts")
            check.expectTrue(currencies.contains("KES"), "KES accounts")
            let apartment = try check.unwrap(accounts.first { $0.name.hasPrefix("Apartment (") })
            check.expect(apartment.currencyCode, "USD", "a property's two-letter tag is not a currency")
            check.expect(apartment.onBudget, false)
        }

        // The merge runs at every launch once syncing is on, over a budget that never had a second
        // device. Anything it found here would be two real envelopes folded into one.
        check.test("finds nothing in the real budget to merge") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            try YNABImport.commit(try YNABImport.read(archiveAt: url), into: context)
            check.expect(try SyncMerge.mergeDuplicates(in: context), SyncMerge.Merges())
        }

        // The register runs to August 2027, so counting every entry would report a working balance
        // that is thousands of dollars out. These totals are what the accounts actually hold on the
        // export date.
        check.test("reports what the accounts hold today, not once the future arrives") {
            let container = try EmbersStore.inMemoryContainer()
            let context = ModelContext(container)
            let budget = try YNABImport.read(archiveAt: url)
            try YNABImport.commit(budget, into: context)

            let closingMonth = try check.unwrap(budget.report.lastMonth)
            let cutoff = YNABImport.reconciliationCutoff(
                exportedAt: budget.report.sourceExportedAt,
                closingMonth: closingMonth
            )
            let result = BudgetEngine().compute(
                try BudgetInputBuilder.build(from: context),
                asOf: cutoff,
                through: closingMonth
            )

            let accounts = try context.fetch(FetchDescriptor<Account>())
            func total(_ matching: (Account) -> Bool) -> MinorUnits {
                accounts.filter(matching).reduce(0) { $0 + (result.accountBalances[$1.identifier] ?? 0) }
            }

            let cash = total { $0.onBudget && !$0.type.isCredit }
            let cards = total { $0.onBudget && $0.type.isCredit }
            check.expect(cash, 801_551, "on-budget cash")
            check.expect(cards, -92_548, "credit card debt")
            check.expect(cash + cards, 709_003, "on budget in total")

            // Money still to come is kept apart rather than folded into today's figure.
            let upcoming = accounts.reduce(0) { $0 + result.upcoming(for: $1.identifier) }
            check.expectTrue(upcoming != 0, "the export carries future-dated transactions")
        }

        check.test("recomputes the real budget fast enough to do it on every change") {
            let container = try EmbersStore.inMemoryContainer()
            let context = ModelContext(container)
            try YNABImport.commit(try YNABImport.read(archiveAt: url), into: context)

            let input = try BudgetInputBuilder.build(from: context)
            let started = Date()
            let result = BudgetEngine().compute(input, asOf: .endOfBudgetDay(), through: YearMonth(containing: Date()))
            let elapsed = Date().timeIntervalSince(started)
            check.expectTrue(result.monthsInOrder.count > 80, "months computed")
            check.expectTrue(elapsed < 1.0, String(format: "recompute took %.3fs", elapsed))
            print(String(format: "      recomputed %d entries in %.3fs", input.entries.count, elapsed))
        }
    }
}
