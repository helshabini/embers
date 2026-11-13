import Foundation
import EmbersCore
import EmbersData
import SwiftData

/// Spending broken down by category, group and payee, narrowed by drilling in, and the cash-flow
/// figures that have to add up for the diagram's columns to meet.
@MainActor
func reportBreakdownChecks(_ check: Checker) {
    let january = YearMonth(year: 2026, month: 1)
    let february = YearMonth(year: 2026, month: 2)

    func day(_ month: YearMonth, _ day: Int) -> Date {
        .budgetDay(year: month.year, month: month.month, day: day)
    }

    let checking = BudgetAccount(name: "Checking", type: .checking)
    let inflow = BudgetCategory(name: "Ready to Assign", groupName: "Inflow", kind: .inflowReadyToAssign)
    let groceries = BudgetCategory(name: "Groceries", groupName: "Immediate Obligations")
    let rent = BudgetCategory(name: "Rent", groupName: "Immediate Obligations")
    let dining = BudgetCategory(name: "Dining Out", groupName: "Just for Fun")
    let cardPayment = BudgetCategory(name: "Card", groupName: "Credit Card Payments", kind: .creditCardPayment)
    let employer = UUID(), market = UUID(), landlord = UUID(), bistro = UUID()

    let input = BudgetInput(
        accounts: [checking],
        categories: [inflow, groceries, rent, dining, cardPayment],
        entries: [
            BudgetEntry(accountID: checking.id, date: day(january, 1), categoryID: inflow.id, amount: 400_000, payeeID: employer),
            BudgetEntry(accountID: checking.id, date: day(january, 2), categoryID: inflow.id, amount: 20_000),
            BudgetEntry(accountID: checking.id, date: day(january, 3), categoryID: rent.id, amount: -150_000, payeeID: landlord),
            BudgetEntry(accountID: checking.id, date: day(january, 5), categoryID: groceries.id, amount: -30_000, payeeID: market),
            BudgetEntry(accountID: checking.id, date: day(january, 9), categoryID: dining.id, amount: -8_000, payeeID: market),
            BudgetEntry(accountID: checking.id, date: day(january, 12), categoryID: dining.id, amount: -12_000, payeeID: bistro),
            // Refunded in full: nets to nothing, and must not appear at all.
            BudgetEntry(accountID: checking.id, date: day(january, 14), categoryID: dining.id, amount: 12_000, payeeID: bistro),
            BudgetEntry(accountID: checking.id, date: day(january, 20), categoryID: groceries.id, amount: -4_000),
            // Money set aside for a card is not spending, whoever it names.
            BudgetEntry(accountID: checking.id, date: day(january, 25), categoryID: cardPayment.id, amount: -50_000, payeeID: market),
            BudgetEntry(accountID: checking.id, date: day(february, 4), categoryID: groceries.id, amount: -25_000, payeeID: market),
        ],
        payeeNames: [employer: "Employer", market: "Market", landlord: "Landlord", bistro: "Bistro"]
    )

    check.suite("Breaking spending down") {
        check.test("by payee, netting refunds, with no payee a share of its own") {
            let shares = ReportBuilder.spending(input, from: january, through: january, by: .payee)
            check.expect(shares.map(\.name), ["Landlord", "Market", ""])
            check.expect(shares.map(\.amount), [150_000, 38_000, 4_000])
            check.expect(shares.last?.key, .payee(nil))
        }

        check.test("by group adds up its categories") {
            let shares = ReportBuilder.spending(input, from: january, through: january, by: .group)
            check.expect(shares.map(\.name), ["Immediate Obligations", "Just for Fun"])
            check.expect(shares.map(\.amount), [184_000, 8_000])
        }

        check.test("drilling in narrows to what matches every step") {
            let inGroup = ReportBuilder.spending(
                input, from: january, through: january, by: .category,
                matching: [.group("Immediate Obligations")]
            )
            check.expect(inGroup.map(\.name), ["Rent", "Groceries"])

            let atMarket = ReportBuilder.spending(
                input, from: january, through: february, by: .category, matching: [.payee(market)]
            )
            check.expect(atMarket.map(\.name), ["Groceries", "Dining Out"], "the card payment named Market is not spending")
            check.expect(atMarket.map(\.amount), [55_000, 8_000])

            let trend = ReportBuilder.monthlySpending(
                input, from: january, through: february, matching: [.category(groceries.id), .payee(market)]
            )
            check.expect(trend.map(\.amount), [30_000, 25_000])
        }

        check.test("money that left by transfer is named after where it went") {
            let apartment = BudgetAccount(name: "Apartment", type: .otherAsset)
            var withMortgage = input
            withMortgage.accounts.append(apartment)
            withMortgage.entries.append(BudgetEntry(
                accountID: checking.id, date: day(january, 28), categoryID: rent.id, amount: -90_000,
                transferCounterAccountID: apartment.id
            ))
            let shares = ReportBuilder.spending(withMortgage, from: january, through: january, by: .payee)
            check.expect(shares.first { $0.key == .transfer(to: apartment.id) }?.name, "Apartment")
            check.expect(shares.first { $0.key == .payee(nil) }?.amount, 4_000, "and is not counted as no payee")
            let into = ReportBuilder.spending(
                withMortgage, from: january, through: january, by: .category, matching: [.transfer(to: apartment.id)]
            )
            check.expect(into.map(\.amount), [90_000])
        }

        check.test("the cash flow's two sides meet") {
            let flow = ReportBuilder.cashFlow(input, from: january, through: january)
            check.expect(flow.income, 420_000)
            check.expect(flow.spending, 192_000)
            check.expect(flow.saved, 228_000)
            check.expect(flow.fromSavings, 0)
            check.expect(flow.sources.map(\.name), ["Employer", ""])
            check.expect(flow.groups.reduce(0) { $0 + $1.amount }, flow.spending)
            for group in flow.groups {
                check.expect(group.children.reduce(0) { $0 + $1.amount }, group.amount, "a group's categories make up the group")
            }
        }

        check.test("spending beyond income is drawn as coming from savings") {
            let flow = ReportBuilder.cashFlow(input, from: february, through: february)
            check.expect(flow.income, 0)
            check.expect(flow.fromSavings, 25_000)
            check.expect(flow.total, 25_000)
        }

        check.test("the tail is folded into one, but never just one") {
            let many = (1...8).map { BudgetCategory(name: "C\($0)", groupName: "G\($0)") }
            let wide = BudgetInput(
                accounts: [checking],
                categories: many,
                entries: many.enumerated().map { index, category in
                    BudgetEntry(accountID: checking.id, date: day(january, 1), categoryID: category.id, amount: MinorUnits(-1_000 * (index + 1)))
                }
            )
            let flow = ReportBuilder.cashFlow(wide, from: january, through: january, groupLimit: 6)
            check.expect(flow.groups.count, 7)
            check.expect(flow.groups.last?.foldedCount, 2)
            check.expect(flow.groups.last?.amount, 3_000)

            let seven = ReportBuilder.cashFlow(wide, from: january, through: january, groupLimit: 7)
            check.expect(seven.groups.count, 8, "folding the last one alone would only hide its name")
        }
    }

    check.suite("Payees reach the reports") {
        check.test("a split's lines are the parent's payee's") {
            let url = URL.temporaryDirectory.appending(path: "report-payees-\(UUID().uuidString).store")
            let context = ModelContext(try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url))
            let account = Account(name: "Cash", type: .cash)
            let payee = Payee(name: "Market")
            let food = BudgetCategoryModel(name: "Groceries")
            context.insert(account)
            context.insert(payee)
            context.insert(food)
            let parent = LedgerTransaction(date: day(january, 3), amountMinor: -5_000, account: account, payee: payee)
            context.insert(parent)
            context.insert(LedgerTransaction(date: day(january, 3), amountMinor: -3_000, account: account, category: food, parent: parent))
            context.insert(LedgerTransaction(date: day(january, 3), amountMinor: -2_000, account: account, category: food, parent: parent))
            try context.save()

            let reopened = ModelContext(try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url))
            let built = try BudgetInputBuilder.build(from: reopened, withPayees: true)
            check.expect(built.entries.count, 2, "the parent is not counted again")
            check.expect(Set(built.entries.map(\.payeeID)), [payee.identifier])
            check.expect(built.payeeNames[payee.identifier], "Market")

            let plain = try BudgetInputBuilder.build(from: reopened)
            check.expectTrue(plain.entries.allSatisfy { $0.payeeID == nil }, "a recompute does not pay for payees")
        }
    }
}
