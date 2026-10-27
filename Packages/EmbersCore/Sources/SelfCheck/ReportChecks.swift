import Foundation
import EmbersCore
import EmbersData
import SwiftData

@MainActor
func reportChecks(_ check: Checker) {
    let january = YearMonth(year: 2026, month: 1)
    let february = YearMonth(year: 2026, month: 2)

    /// Income, a card purchase, a cash purchase, a refund, and a card payment.
    func makeInput() -> (BudgetInput, BudgetCategory, BudgetCategory, BudgetAccount) {
        let checking = BudgetAccount(name: "Checking", type: .checking)
        let card = BudgetAccount(name: "Card", type: .creditCard)
        let brokerage = BudgetAccount(name: "Brokerage", type: .investment)
        let inflow = BudgetCategory(name: "Ready to Assign", groupName: "Inflow", kind: .inflowReadyToAssign)
        let groceries = BudgetCategory(name: "Groceries", groupName: "Immediate Obligations")
        let dining = BudgetCategory(name: "Dining Out", groupName: "Just for Fun")
        let cardPayment = BudgetCategory(
            name: "Card", groupName: "Credit Card Payments",
            kind: .creditCardPayment, linkedAccountID: card.id
        )

        func day(_ month: YearMonth, _ day: Int) -> Date {
            .budgetDay(year: month.year, month: month.month, day: day)
        }

        let input = BudgetInput(
            accounts: [checking, card, brokerage],
            categories: [inflow, groceries, dining, cardPayment],
            entries: [
                BudgetEntry(accountID: checking.id, date: day(january, 1),
                            categoryID: inflow.id, amount: 500_000),
                BudgetEntry(accountID: card.id, date: day(january, 5),
                            categoryID: groceries.id, amount: -30_000),
                BudgetEntry(accountID: checking.id, date: day(january, 8),
                            categoryID: dining.id, amount: -12_000),
                // A refund nets off rather than reading as income.
                BudgetEntry(accountID: card.id, date: day(january, 20),
                            categoryID: groceries.id, amount: 5_000),
                // Paying the card is not a second purchase.
                BudgetEntry(accountID: checking.id, date: day(january, 28),
                            amount: -25_000, transferCounterAccountID: card.id),
                BudgetEntry(accountID: card.id, date: day(january, 28),
                            amount: 25_000, transferCounterAccountID: checking.id),
                BudgetEntry(accountID: brokerage.id, date: day(january, 30),
                            categoryID: inflow.id, amount: 200_000),
                BudgetEntry(accountID: checking.id, date: day(february, 3),
                            categoryID: groceries.id, amount: -20_000),
            ],
            assignments: []
        )
        return (input, groceries, dining, card)
    }

    check.suite("Reports") {
        check.test("counts income and spending per month, netting refunds") {
            let (input, _, _, _) = makeInput()
            let flows = ReportBuilder.flows(input, from: january, through: february)
            check.expect(flows.count, 2)
            // 500,000 into the budget plus 200,000 into the brokerage.
            check.expect(flows[0].income, 700_000)
            // 30,000 groceries − 5,000 refund + 12,000 dining.
            check.expect(flows[0].spending, 37_000)
            check.expect(flows[0].net, 663_000)
            check.expect(flows[1].income, 0)
            check.expect(flows[1].spending, 20_000)
        }

        // Moving money to a card's payment category is budget activity, not a purchase.
        check.test("leaves card payments out of spending") {
            let (input, _, _, _) = makeInput()
            let flows = ReportBuilder.flows(input, from: january, through: january)
            check.expectTrue(flows[0].spending < 62_000, "card payment must not count as spending")
            check.expect(flows[0].spending, 37_000)
        }

        check.test("breaks spending down by category, largest first") {
            let (input, groceries, dining, _) = makeInput()
            let slices = ReportBuilder.spendingByCategory(input, from: january, through: february)
            check.expect(slices.count, 2)
            check.expect(slices[0].categoryID, groceries.id)
            // 30,000 − 5,000 refund + 20,000 in February.
            check.expect(slices[0].amount, 45_000)
            check.expect(slices[1].categoryID, dining.id)
            check.expect(slices[1].amount, 12_000)
            check.expect(slices[0].groupName, "Immediate Obligations")
        }

        check.test("honours the range it is asked for") {
            let (input, _, dining, _) = makeInput()
            let slices = ReportBuilder.spendingByCategory(input, from: february, through: february)
            check.expect(slices.count, 1)
            check.expectTrue(slices.first?.categoryID != dining.id)
            check.expect(slices.first?.amount, 20_000)
        }

        check.test("tracks net worth, separating what is owed") {
            let (input, _, _, _) = makeInput()
            let points = ReportBuilder.netWorth(input, from: january, through: february)
            check.expect(points.count, 2)
            // Checking 500,000 − 12,000 − 25,000 = 463,000, plus brokerage 200,000.
            check.expect(points[0].assets, 663_000)
            // Card: −30,000 + 5,000 + 25,000 = 0.
            check.expect(points[0].liabilities, 0)
            check.expect(points[0].net, 663_000)
            check.expect(points[1].assets, 643_000)
            check.expect(points[1].net, 643_000)
        }

        check.test("ignores what has not happened yet") {
            let (input, _, _, _) = makeInput()
            let flows = ReportBuilder.flows(
                input, from: january, through: february,
                asOf: .budgetDay(year: 2026, month: 1, day: 31)
            )
            check.expect(flows[1].spending, 0, "February has not happened yet")
        }
    }

    check.suite("Payee memory") {
        func makeStore() throws -> (ModelContext, BudgetCategoryModel, BudgetCategoryModel, Payee) {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let group = CategoryGroup(name: "Immediate Obligations")
            let groceries = BudgetCategoryModel(name: "Groceries", group: group)
            let dining = BudgetCategoryModel(name: "Dining Out", group: group)
            let account = Account(name: "Cash", type: .cash)
            let carretaMarket = Payee(name: "Carreta Market")
            for object in [group] { context.insert(object) }
            context.insert(groceries)
            context.insert(dining)
            context.insert(account)
            context.insert(carretaMarket)
            context.insert(
                LedgerTransaction(
                    date: .budgetDay(year: 2026, month: 1, day: 5), amountMinor: -3_000,
                    account: account, payee: carretaMarket, category: groceries
                )
            )
            try context.save()
            return (context, groceries, dining, carretaMarket)
        }

        check.test("recalls the category a payee was last filed under") {
            let (context, groceries, _, _) = try makeStore()
            let recalled = try PayeeMemory.lastCategory(forPayeeNamed: "Carreta Market", in: context)
            check.expect(recalled?.identifier, groceries.identifier)
        }

        check.test("matches the payee however it was typed") {
            let (context, groceries, _, _) = try makeStore()
            check.expect(
                try PayeeMemory.lastCategory(forPayeeNamed: "  carreta market ", in: context)?.identifier,
                groceries.identifier
            )
        }

        // A payee that has moved category should repeat the newest choice, not the oldest.
        check.test("prefers the most recent choice over the most frequent") {
            let (context, _, dining, carretaMarket) = try makeStore()
            let account = try check.unwrap(try context.fetch(FetchDescriptor<Account>()).first)
            context.insert(
                LedgerTransaction(
                    date: .budgetDay(year: 2026, month: 3, day: 1), amountMinor: -4_000,
                    account: account, payee: carretaMarket, category: dining
                )
            )
            try context.save()
            check.expect(
                try PayeeMemory.lastCategory(forPayeeNamed: "Carreta Market", in: context)?.identifier,
                dining.identifier
            )
        }

        check.test("knows nothing about a payee it has not seen") {
            let (context, _, _, _) = try makeStore()
            check.expectNil(try PayeeMemory.lastCategory(forPayeeNamed: "Unknown Shop", in: context))
            check.expectNil(try PayeeMemory.lastCategory(forPayeeNamed: "   ", in: context))
        }

        check.test("suggests payees by prefix first") {
            let (context, _, _, _) = try makeStore()
            context.insert(Payee(name: "Carphone Warehouse"))
            context.insert(Payee(name: "Superbrand Carrots"))
            try context.save()

            let names = try PayeeMemory.suggestions(matching: "car", in: context).map(\.name)
            check.expectTrue(names.count >= 2, "\(names)")
            check.expectTrue(
                names.firstIndex(of: "Superbrand Carrots") ?? 99 > 1,
                "a prefix match should outrank one that merely contains it: \(names)"
            )
        }

        check.test("still offers a payee once its whole name is typed, ahead of the rest") {
            let (context, _, _, _) = try makeStore()
            context.insert(Payee(name: "Brother", lastUsedAt: Date()))
            context.insert(Payee(name: "Other", lastUsedAt: .distantPast))
            context.insert(Payee(name: "Otherworld", lastUsedAt: Date()))
            try context.save()

            let names = try PayeeMemory.suggestions(matching: "other", in: context).map(\.name)
            check.expect(names.first, "Other", "choosing it is what fills in its category: \(names)")
            check.expectTrue(names.contains("Brother"), "\(names)")
        }
    }

    check.suite("Clearing from a list") {
        func makeTransaction(_ status: ClearedStatus) throws -> (ModelContext, LedgerTransaction) {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let account = Account(name: "Cash", type: .cash)
            context.insert(account)
            let transaction = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 1, day: 5), amountMinor: -3_000,
                cleared: status, account: account
            )
            context.insert(transaction)
            try context.save()
            return (context, transaction)
        }

        check.test("flips between cleared and uncleared") {
            let (context, transaction) = try makeTransaction(.uncleared)
            try ClearedStatusWriter.toggleCleared(transaction, in: context)
            check.expect(transaction.cleared, .cleared)
            try ClearedStatusWriter.toggleCleared(transaction, in: context)
            check.expect(transaction.cleared, .uncleared)
        }

        // Reconciling means it was checked against a statement; a swipe must not undo that.
        check.test("leaves a reconciled entry alone") {
            let (context, transaction) = try makeTransaction(.reconciled)
            try ClearedStatusWriter.toggleCleared(transaction, in: context)
            check.expect(transaction.cleared, .reconciled)
            check.expect(ClearedStatusWriter.canToggle(transaction), false)
        }
    }
}
