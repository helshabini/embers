import Foundation
import EmbersCore
import EmbersData
import SwiftData

@MainActor
func transferChecks(_ check: Checker) {
    let january = YearMonth(year: 2026, month: 1)
    let date = Date.budgetDay(year: 2026, month: 1, day: 15)

    func makeStore() throws -> (ModelContext, Account, Account, Account) {
        let context = ModelContext(try EmbersStore.inMemoryContainer())
        let checking = Account(name: "Checking", type: .checking)
        let savings = Account(name: "Savings", type: .savings)
        let brokerage = Account(name: "Brokerage", type: .investment)
        context.insert(checking)
        context.insert(savings)
        context.insert(brokerage)
        try context.save()
        return (context, checking, savings, brokerage)
    }

    check.suite("Transfers") {
        check.test("writes both sides, one out and one in") {
            let (context, checking, savings, _) = try makeStore()
            TransferWriter.makeTransfer(
                amountMinor: 25_000, from: checking, to: savings, date: date, in: context
            )
            try context.save()

            let all = try context.fetch(FetchDescriptor<LedgerTransaction>())
            check.expect(all.count, 2)
            let outgoing = try check.unwrap(all.first { $0.account?.name == "Checking" })
            let incoming = try check.unwrap(all.first { $0.account?.name == "Savings" })
            check.expect(outgoing.amountMinor, -25_000)
            check.expect(incoming.amountMinor, 25_000)
            check.expect(outgoing.transferCounterAccount?.name, "Savings")
            check.expect(incoming.transferCounterAccount?.name, "Checking")
            check.expect(outgoing.transferPairIdentifier, incoming.transferPairIdentifier)
        }

        check.test("moves the balance without changing net worth or Ready to Assign") {
            let (context, checking, savings, _) = try makeStore()
            let inflowGroup = CategoryGroup(name: "Inflow")
            let inflow = BudgetCategoryModel(
                name: "Ready to Assign", group: inflowGroup, kind: .inflowReadyToAssign
            )
            context.insert(inflowGroup)
            context.insert(inflow)
            context.insert(
                LedgerTransaction(
                    date: Date.budgetDay(year: 2026, month: 1, day: 1),
                    amountMinor: 100_000, account: checking, category: inflow
                )
            )
            try context.save()

            let engine = BudgetEngine()
            let before = engine.compute(try BudgetInputBuilder.build(from: context), through: january)

            TransferWriter.makeTransfer(
                amountMinor: 25_000, from: checking, to: savings, date: date, in: context
            )
            try context.save()
            let after = engine.compute(try BudgetInputBuilder.build(from: context), through: january)

            check.expect(after.accountBalances[checking.identifier], 75_000)
            check.expect(after.accountBalances[savings.identifier], 25_000)
            check.expect(after.netWorth, before.netWorth, "a transfer creates no money")
            check.expect(
                after.readyToAssign(in: january),
                before.readyToAssign(in: january),
                "moving between budget accounts does not change what is left to assign"
            )
        }

        check.test("finds both sides from either one, and deletes them together") {
            let (context, checking, savings, _) = try makeStore()
            let sides = TransferWriter.makeTransfer(
                amountMinor: 25_000, from: checking, to: savings, date: date, in: context
            )
            try context.save()

            check.expect(try TransferWriter.pair(of: sides.outgoing, in: context).count, 2)
            check.expect(try TransferWriter.pair(of: sides.incoming, in: context).count, 2)

            try TransferWriter.deleteTransfer(sides.incoming, in: context)
            check.expect(
                try context.fetchCount(FetchDescriptor<LedgerTransaction>()),
                0,
                "deleting one side must not leave the other stranded"
            )
        }

        check.test("keeps the counterpart in step when one side is edited") {
            let (context, checking, savings, _) = try makeStore()
            let sides = TransferWriter.makeTransfer(
                amountMinor: 25_000, from: checking, to: savings, date: date, in: context
            )
            try context.save()

            sides.outgoing.amountMinor = -40_000
            sides.outgoing.memo = "rent"
            try TransferWriter.syncCounterpart(of: sides.outgoing, in: context)

            check.expect(sides.incoming.amountMinor, 40_000)
            check.expect(sides.incoming.memo, "rent")
        }

        check.test("deleting one side of a transfer takes the other with it") {
            let (context, checking, savings, _) = try makeStore()
            let sides = TransferWriter.makeTransfer(
                amountMinor: 25_000, from: checking, to: savings, date: date, in: context
            )
            try context.save()

            let removed = try TransactionWriter.delete(sides.incoming, in: context)
            check.expect(removed, 2)
            check.expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 0)

            let result = BudgetEngine().compute(
                try BudgetInputBuilder.build(from: context), through: january
            )
            check.expect(result.accountBalances[checking.identifier] ?? 0, 0)
            check.expect(result.accountBalances[savings.identifier] ?? 0, 0)
        }

        check.test("deleting an ordinary transaction removes only that one") {
            let (context, checking, savings, _) = try makeStore()
            let kept = LedgerTransaction(date: date, amountMinor: -1_000, account: checking)
            let doomed = LedgerTransaction(date: date, amountMinor: -2_000, account: savings)
            context.insert(kept)
            context.insert(doomed)
            try context.save()

            check.expect(try TransactionWriter.delete(doomed, in: context), 1)
            check.expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 1)
        }

        check.test("deleting a split parent takes its lines") {
            let (context, checking, _, _) = try makeStore()
            let parent = LedgerTransaction(date: date, amountMinor: -5_000, account: checking)
            context.insert(parent)
            for amount in [-3_000, -2_000] {
                context.insert(
                    LedgerTransaction(date: date, amountMinor: amount, account: checking, parent: parent)
                )
            }
            try context.save()
            check.expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 3)

            try TransactionWriter.delete(parent, in: context)
            check.expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 0)
        }

        check.test("says what a deletion will take with it") {
            let (context, checking, savings, _) = try makeStore()
            let sides = TransferWriter.makeTransfer(
                amountMinor: 1_000, from: checking, to: savings, date: date, in: context
            )
            try context.save()
            let summary = TransactionWriter.deletionSummary(sides.outgoing, in: context)
            check.expectTrue(summary.contains("Savings"), summary)

            let plain = LedgerTransaction(date: date, amountMinor: -500, account: checking)
            context.insert(plain)
            check.expectTrue(
                !TransactionWriter.deletionSummary(plain, in: context).contains("transfer"),
                "a plain entry should not mention transfers"
            )
        }

        // Moving money to a tracking account leaves the budget, so it carries a category.
        check.test("a categorised transfer to a tracking account counts as spending") {
            let (context, checking, _, brokerage) = try makeStore()
            let group = CategoryGroup(name: "Quality of Life Goals")
            let investing = BudgetCategoryModel(name: "Investing", group: group)
            context.insert(group)
            context.insert(investing)

            TransferWriter.makeTransfer(
                amountMinor: 50_000, from: checking, to: brokerage, date: date,
                category: investing, in: context
            )
            try context.save()

            let result = BudgetEngine().compute(
                try BudgetInputBuilder.build(from: context), through: january
            )
            check.expect(result.state(of: investing.identifier, in: january).activity, -50_000)
            check.expect(result.accountBalances[brokerage.identifier], 50_000)
        }
    }
}
