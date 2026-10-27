import Foundation
import EmbersCore
import EmbersData
import SwiftData

@MainActor
func accountAndReconcileChecks(_ check: Checker) {
    let january = YearMonth(year: 2026, month: 1)
    let opened = Date.budgetDay(year: 2026, month: 1, day: 1)
    let mid = Date.budgetDay(year: 2026, month: 1, day: 15)

    func store() throws -> ModelContext {
        ModelContext(try EmbersStore.inMemoryContainer())
    }

    check.suite("Adding an account") {
        check.test("an opening balance lands in Ready to Assign") {
            let context = try store()
            let account = try AccountWriter.create(
                name: "New Checking", type: .checking, currencyCode: "USD",
                startingBalanceMinor: 250_000, startingDate: opened, in: context
            )

            let result = BudgetEngine().compute(
                try BudgetInputBuilder.build(from: context), through: january
            )
            check.expect(result.accountBalances[account.identifier], 250_000)
            check.expect(
                result.readyToAssign(in: january), 250_000,
                "money that was already there is money to assign"
            )
        }

        check.test("a tracking account's opening balance stays out of the budget") {
            let context = try store()
            let account = try AccountWriter.create(
                name: "Brokerage", type: .investment, currencyCode: "USD",
                startingBalanceMinor: 1_000_000, startingDate: opened, in: context
            )
            check.expectTrue(!account.onBudget, "an investment account tracks, it does not budget")

            let result = BudgetEngine().compute(
                try BudgetInputBuilder.build(from: context), through: january
            )
            check.expect(result.accountBalances[account.identifier], 1_000_000)
            check.expect(result.readyToAssign(in: january), 0, "tracking money is not assignable")
            check.expect(result.netWorth, 1_000_000, "but it is still net worth")
        }

        check.test("a credit card gets its payment category, named after it") {
            let context = try store()
            let card = try AccountWriter.create(
                name: "Travel Visa", type: .creditCard, currencyCode: "USD",
                startingBalanceMinor: -50_000, startingDate: opened, in: context
            )

            let categories = try context.fetch(FetchDescriptor<BudgetCategoryModel>())
            let payment = try check.unwrap(categories.first { $0.kind == .creditCardPayment })
            check.expect(payment.name, "Travel Visa")
            check.expect(payment.linkedAccount?.identifier, card.identifier)
            check.expect(payment.group?.name, "Credit Card Payments")

            let result = BudgetEngine().compute(
                try BudgetInputBuilder.build(from: context), through: january
            )
            check.expect(result.accountBalances[card.identifier], -50_000)
            // The export records a card's opening debt exactly this way — Orbit Business carries a
            // $2,000 outflow against Inflow: Ready to Assign — so opening in debt really does leave
            // Ready to Assign short. That is the one case the floor at zero gives way for: the money
            // is owed whether or not it has been budgeted.
            check.expect(
                result.readyToAssign(in: january), -50_000,
                "debt you have not budgeted for is a shortfall, not zero"
            )
        }

        check.test("a zero opening balance writes no transaction at all") {
            let context = try store()
            try AccountWriter.create(
                name: "Empty", type: .cash, currencyCode: "USD", in: context
            )
            check.expect(
                try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 0,
                "a $0.00 opening row is noise"
            )
        }

        check.test("new accounts queue up after the ones already there") {
            let context = try store()
            let first = try AccountWriter.create(name: "A", type: .cash, currencyCode: "USD", in: context)
            let second = try AccountWriter.create(name: "B", type: .cash, currencyCode: "USD", in: context)
            check.expectTrue(second.order > first.order, "a new account goes last, not on top")
        }

        check.test("the inflow category is made once and then reused") {
            let context = try store()
            try AccountWriter.create(
                name: "A", type: .checking, currencyCode: "USD",
                startingBalanceMinor: 100, startingDate: opened, in: context
            )
            try AccountWriter.create(
                name: "B", type: .checking, currencyCode: "USD",
                startingBalanceMinor: 100, startingDate: opened, in: context
            )
            let inflows = try context.fetch(FetchDescriptor<BudgetCategoryModel>())
                .filter { $0.kind == .inflowReadyToAssign }
            check.expect(inflows.count, 1, "there is only ever one Ready to Assign")
        }
    }

    check.suite("Reconciling an account") {
        /// An account holding 100 cleared and 30 uncleared.
        @MainActor func accountWithMixedRows(_ context: ModelContext) throws -> Account {
            let account = try AccountWriter.create(
                name: "Checking", type: .checking, currencyCode: "USD",
                startingBalanceMinor: 100_00, startingDate: opened, in: context
            )
            let pending = LedgerTransaction(
                date: mid, amountMinor: -30_00, cleared: .uncleared, account: account
            )
            context.insert(pending)
            try context.save()
            return account
        }

        check.test("the cleared balance ignores what the bank has not seen") {
            let context = try store()
            let account = try accountWithMixedRows(context)
            let plan = try ReconcileWriter.plan(
                for: account, statementBalanceMinor: 100_00, asOf: mid, in: context
            )
            check.expect(plan.clearedBalanceMinor, 100_00)
            check.expect(plan.differenceMinor, 0)
            check.expectTrue(!plan.needsAdjustment, "an agreeing statement needs no adjustment")
        }

        check.test("comparing another figure gives what a fresh read would") {
            // The screen reads the account once and compares each keystroke against that.
            let context = try store()
            let account = try accountWithMixedRows(context)
            let read = try ReconcileWriter.plan(
                for: account, statementBalanceMinor: 0, asOf: mid, in: context
            )
            let fresh = try ReconcileWriter.plan(
                for: account, statementBalanceMinor: 87_50, asOf: mid, in: context
            )
            check.expect(read.comparing(to: 87_50), fresh)
            check.expect(fresh.differenceMinor, -12_50)
        }

        check.test("a statement that disagrees produces one adjustment for the difference") {
            let context = try store()
            let account = try accountWithMixedRows(context)
            let adjustment = try check.unwrap(
                try ReconcileWriter.reconcile(
                    account, statementBalanceMinor: 95_00, asOf: mid, in: context
                )
            )
            check.expect(adjustment.amountMinor, -5_00, "the bank says five dollars less")
            check.expect(adjustment.cleared, .reconciled)
            check.expect(adjustment.category?.kind, .inflowReadyToAssign)

            let result = BudgetEngine().compute(
                try BudgetInputBuilder.build(from: context), through: january
            )
            check.expect(
                result.accountBalances[account.identifier], 65_00,
                "95 cleared, less the 30 still pending"
            )
        }

        check.test("reconciling locks what has cleared and leaves the rest alone") {
            let context = try store()
            let account = try accountWithMixedRows(context)
            try ReconcileWriter.reconcile(
                account, statementBalanceMinor: 100_00, asOf: mid, in: context
            )

            let rows = try context.fetch(FetchDescriptor<LedgerTransaction>())
            check.expect(rows.filter { $0.cleared == .reconciled }.count, 1)
            check.expect(
                rows.filter { $0.cleared == .uncleared }.count, 1,
                "a pending row is not something a statement can confirm"
            )
        }

        check.test("an agreeing statement writes no adjustment row") {
            let context = try store()
            let account = try accountWithMixedRows(context)
            let before = try context.fetchCount(FetchDescriptor<LedgerTransaction>())
            let adjustment = try ReconcileWriter.reconcile(
                account, statementBalanceMinor: 100_00, asOf: mid, in: context
            )
            check.expectNil(adjustment)
            check.expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), before)
        }

        check.test("a tracking account reconciles without touching Ready to Assign") {
            let context = try store()
            let account = try AccountWriter.create(
                name: "Brokerage", type: .investment, currencyCode: "USD",
                startingBalanceMinor: 1_000_00, startingDate: opened, in: context
            )
            let adjustment = try check.unwrap(
                try ReconcileWriter.reconcile(
                    account, statementBalanceMinor: 1_200_00, asOf: mid, in: context
                )
            )
            check.expect(adjustment.amountMinor, 200_00, "the market moved")
            check.expectNil(adjustment.category, "growth off-budget is not income to assign")

            let result = BudgetEngine().compute(
                try BudgetInputBuilder.build(from: context), through: january
            )
            check.expect(result.readyToAssign(in: january), 0)
            check.expect(result.accountBalances[account.identifier], 1_200_00)
        }

        check.test("reconciling twice is quiet the second time") {
            let context = try store()
            let account = try accountWithMixedRows(context)
            try ReconcileWriter.reconcile(account, statementBalanceMinor: 95_00, asOf: mid, in: context)
            let second = try ReconcileWriter.reconcile(
                account, statementBalanceMinor: 95_00, asOf: mid, in: context
            )
            check.expectNil(second, "nothing has changed, so nothing should be written")
        }

        check.test("a card reconciles against what is owed") {
            let context = try store()
            let card = try AccountWriter.create(
                name: "Visa", type: .creditCard, currencyCode: "USD",
                startingBalanceMinor: -200_00, startingDate: opened, in: context
            )
            let adjustment = try check.unwrap(
                try ReconcileWriter.reconcile(
                    card, statementBalanceMinor: -250_00, asOf: mid, in: context
                )
            )
            check.expect(adjustment.amountMinor, -50_00, "the statement says fifty more is owed")
            let result = BudgetEngine().compute(
                try BudgetInputBuilder.build(from: context), through: january
            )
            check.expect(result.accountBalances[card.identifier], -250_00)
        }
    }
}
