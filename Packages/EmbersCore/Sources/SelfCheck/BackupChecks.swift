import Foundation
import EmbersCore
import EmbersData
import SwiftData

@MainActor
func backupChecks(_ check: Checker) {
    let january = YearMonth(year: 2026, month: 1)

    check.suite("Backup and restore") {
        check.test("round-trips a budget without changing what the engine computes") {
            let source = ModelContext(try EmbersStore.inMemoryContainer())
            let group = CategoryGroup(name: "Immediate Obligations")
            let groceries = BudgetCategoryModel(name: "Groceries", group: group)
            let inflowGroup = CategoryGroup(name: "Inflow")
            let inflow = BudgetCategoryModel(
                name: "Ready to Assign", group: inflowGroup, kind: .inflowReadyToAssign
            )
            let checking = Account(name: "Checking", type: .checking)
            let card = Account(name: "Card", type: .creditCard, currencyCode: "AED")
            let payee = Payee(name: "Carreta Market")
            for object in [group, inflowGroup] { source.insert(object) }
            for object in [groceries, inflow] { source.insert(object) }
            source.insert(checking)
            source.insert(card)
            source.insert(payee)
            source.insert(
                LedgerTransaction(
                    date: .budgetDay(year: 2026, month: 1, day: 2),
                    amountMinor: 100_000, account: checking, category: inflow
                )
            )
            source.insert(
                LedgerTransaction(
                    date: .budgetDay(year: 2026, month: 1, day: 9),
                    amountMinor: -1_949, memo: "groceries", account: card,
                    payee: payee, category: groceries,
                    conversion: CurrencyConversion(
                        enteredAmount: 100_000, enteredCurrencyCode: "EGP", rateToBase: 0.0192,
                        rateAsOf: Date(timeIntervalSince1970: 1_790_000_000),
                        rateSource: "open.er-api.com", isManualRate: false, feePercent: 1.5,
                        convertedBeforeFee: 1_920, feeAmount: 29, baseAmount: 1_949
                    )
                )
            )
            TransferWriter.makeTransfer(
                amountMinor: 25_000, from: checking, to: card,
                date: .budgetDay(year: 2026, month: 1, day: 20), in: source
            )
            try AssignmentWriter.setAssigned(30_000, category: groceries, month: january, in: source)
            try source.save()

            let data = try BackupWriter.data(from: source)
            let before = BudgetEngine().compute(
                try BudgetInputBuilder.build(from: source), through: january
            )

            let destination = ModelContext(try EmbersStore.inMemoryContainer())
            let archive = try BackupWriter.decode(data)
            try BackupWriter.restore(archive, into: destination)
            let after = BudgetEngine().compute(
                try BudgetInputBuilder.build(from: destination), through: january
            )

            check.expect(after.accountBalances, before.accountBalances, "balances")
            check.expect(after.netWorth, before.netWorth, "net worth")
            check.expect(
                after.readyToAssign(in: january), before.readyToAssign(in: january), "ready to assign"
            )
            check.expect(
                after.state(of: groceries.identifier, in: january),
                before.state(of: groceries.identifier, in: january),
                "groceries"
            )
        }

        check.test("keeps payees, currencies, conversions and transfer pairing") {
            let source = ModelContext(try EmbersStore.inMemoryContainer())
            let checking = Account(name: "Checking", type: .checking)
            let card = Account(name: "Card", type: .creditCard, currencyCode: "AED")
            card.fxFeePercentOverride = 1.5
            source.insert(checking)
            source.insert(card)
            TransferWriter.makeTransfer(
                amountMinor: 25_000, from: checking, to: card,
                date: .budgetDay(year: 2026, month: 1, day: 20), in: source
            )
            try source.save()

            let destination = ModelContext(try EmbersStore.inMemoryContainer())
            try BackupWriter.restore(
                try BackupWriter.decode(try BackupWriter.data(from: source)), into: destination
            )

            let restoredCard = try check.unwrap(
                try destination.fetch(FetchDescriptor<Account>()).first { $0.name == "Card" }
            )
            check.expect(restoredCard.currencyCode, "AED")
            check.expect(restoredCard.fxFeePercentOverride, 1.5)

            let restored = try destination.fetch(FetchDescriptor<LedgerTransaction>())
            check.expect(restored.count, 2)
            let pairIdentifiers = Set(restored.compactMap(\.transferPairIdentifier))
            check.expect(pairIdentifiers.count, 1, "both sides keep the same pairing")
            let outgoing = try check.unwrap(restored.first { $0.amountMinor < 0 })
            check.expect(outgoing.transferCounterAccount?.name, "Card")
        }

        check.test("restores a split as a parent with its lines") {
            let source = ModelContext(try EmbersStore.inMemoryContainer())
            let cash = Account(name: "Cash", type: .cash)
            source.insert(cash)
            let parent = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 1, day: 5), amountMinor: -5_000, account: cash
            )
            source.insert(parent)
            for amount in [-3_000, -2_000] {
                source.insert(
                    LedgerTransaction(
                        date: parent.date, amountMinor: amount, account: cash, parent: parent
                    )
                )
            }
            try source.save()

            let destination = ModelContext(try EmbersStore.inMemoryContainer())
            try BackupWriter.restore(
                try BackupWriter.decode(try BackupWriter.data(from: source)), into: destination
            )

            let restored = try destination.fetch(FetchDescriptor<LedgerTransaction>())
            check.expect(restored.count, 3)
            let parents = restored.filter(\.isSplitParent)
            check.expect(parents.count, 1)
            check.expect(parents.first?.splitLines?.count, 2)

            // Only the lines reach the engine, so the balance is counted once.
            let input = try BudgetInputBuilder.build(from: destination)
            check.expect(input.entries.count, 2)
        }

        check.test("replaces whatever was there rather than merging into it") {
            let destination = ModelContext(try EmbersStore.inMemoryContainer())
            destination.insert(Account(name: "Stale", type: .checking))
            try destination.save()

            let source = ModelContext(try EmbersStore.inMemoryContainer())
            source.insert(Account(name: "Fresh", type: .savings))
            try source.save()

            try BackupWriter.restore(
                try BackupWriter.decode(try BackupWriter.data(from: source)), into: destination
            )
            let names = try destination.fetch(FetchDescriptor<Account>()).map(\.name)
            check.expect(names, ["Fresh"])
        }

        check.test("refuses a backup from a newer version instead of dropping data") {
            var json = String(data: try BackupWriter.data(
                from: ModelContext(try EmbersStore.inMemoryContainer())
            ), encoding: .utf8) ?? ""
            json = json.replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 99")
            check.expectThrows { try BackupWriter.decode(Data(json.utf8)) }
        }

        check.test("names the file so backups sort by date") {
            let archive = try BackupWriter.archive(
                from: ModelContext(try EmbersStore.inMemoryContainer())
            )
            let name = BackupWriter.suggestedFileName(for: archive)
            check.expectTrue(name.hasPrefix("Embers Backup "), name)
            check.expectTrue(name.hasSuffix(".embers.json"), name)
        }
    }

    check.suite("Redirecting a transfer") {
        check.test("moves the counterpart to the new account") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let checking = Account(name: "Checking", type: .checking)
            let savings = Account(name: "Savings", type: .savings)
            let cash = Account(name: "Cash", type: .cash)
            for account in [checking, savings, cash] { context.insert(account) }
            let sides = TransferWriter.makeTransfer(
                amountMinor: 25_000, from: checking, to: savings,
                date: .budgetDay(year: 2026, month: 1, day: 20), in: context
            )
            try context.save()

            try TransferWriter.syncCounterpart(of: sides.outgoing, destination: cash, in: context)

            check.expect(sides.incoming.account?.name, "Cash", "the receiving side moved")
            check.expect(sides.outgoing.transferCounterAccount?.name, "Cash")
            check.expect(sides.incoming.transferCounterAccount?.name, "Checking")

            let result = BudgetEngine().compute(
                try BudgetInputBuilder.build(from: context), through: january
            )
            check.expect(result.accountBalances[savings.identifier] ?? 0, 0, "the old account is clear")
            check.expect(result.accountBalances[cash.identifier], 25_000)
            check.expect(result.accountBalances[checking.identifier], -25_000)
        }

        check.test("reports which account is on the other side") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let checking = Account(name: "Checking", type: .checking)
            let savings = Account(name: "Savings", type: .savings)
            context.insert(checking)
            context.insert(savings)
            let sides = TransferWriter.makeTransfer(
                amountMinor: 10_000, from: checking, to: savings,
                date: .budgetDay(year: 2026, month: 1, day: 20), in: context
            )
            try context.save()

            check.expect(
                try TransferWriter.counterpartAccount(of: sides.outgoing, in: context)?.name,
                "Savings"
            )
            check.expect(
                try TransferWriter.counterpartAccount(of: sides.incoming, in: context)?.name,
                "Checking"
            )
        }
    }
}
