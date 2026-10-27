import Foundation
import EmbersCore
import EmbersData
import SwiftData

private let header = """
"Account","Flag","Date","Payee","Category Group/Category","Category Group","Category","Memo","Outflow","Inflow","Cleared"
"""

private let plan = """
"Month","Category Group/Category","Category Group","Category","Assigned","Activity","Available"
"Jan 2026","Credit Card Payments: Atlas MasterCard (EGP)","Credit Card Payments","Atlas MasterCard (EGP)",$0.00,$0.00,$0.00
"Jan 2026","Immediate Obligations: Groceries","Immediate Obligations","Groceries",$300.00,$0.00,$0.00
"Jan 2026","Just for Fun: Dining Out","Just for Fun","Dining Out",$100.00,$0.00,$0.00
"""

private let register = """
\(header)
"Cash (USD)","","01/05/2026","Paycheck","Inflow: Ready to Assign","Inflow","Ready to Assign","",$0.00,$1000.00,"Cleared"
"Atlas MasterCard (EGP)","","01/10/2026","Carreta Market","Immediate Obligations: Groceries","Immediate Obligations","Groceries","",$200.00,$0.00,"Cleared"
"Cash (USD)","","01/12/2026","Apple","Immediate Obligations: Groceries","Immediate Obligations","Groceries","Split (1/2) run",$30.00,$0.00,"Cleared"
"Cash (USD)","","01/12/2026","Apple","Just for Fun: Dining Out","Just for Fun","Dining Out","Split (2/2) run",$20.00,$0.00,"Cleared"
"Cash (USD)","","01/28/2026","Transfer : Atlas MasterCard (EGP)","","","","",$150.00,$0.00,"Cleared"
"Atlas MasterCard (EGP)","","01/28/2026","Transfer : Cash (USD)","","","","",$0.00,$150.00,"Cleared"
"""

@MainActor
func dataChecks(_ check: Checker) {
    check.suite("SwiftData store") {
        let january = YearMonth(year: 2026, month: 1)
        let asOf = Calendar.gregorianUTC.date(
            from: DateComponents(year: 2026, month: 1, day: 31, hour: 23)
        )!

        check.test("round-trips a budget through the store without changing the engine's result") {
            let budget = try YNABImporter().makeBudget(planCSV: plan, registerCSV: register)
            let container = try EmbersStore.inMemoryContainer()
            let context = ModelContext(container)
            try ImportWriter.write(budget, into: context)

            let fromStore = try BudgetInputBuilder.build(from: context)
            let direct = budget.budgetInput()

            let engine = BudgetEngine()
            let storeResult = engine.compute(fromStore, asOf: asOf, through: january)
            let directResult = engine.compute(direct, asOf: asOf, through: january)

            check.expect(fromStore.entries.count, direct.entries.count, "entry count")
            check.expect(fromStore.accounts.count, direct.accounts.count, "account count")
            check.expect(fromStore.assignments.count, direct.assignments.count, "assignment count")
            check.expect(storeResult.accountBalances, directResult.accountBalances, "balances")
            check.expect(storeResult.netWorth, directResult.netWorth, "net worth")
            check.expect(
                storeResult.readyToAssign(in: january),
                directResult.readyToAssign(in: january),
                "ready to assign"
            )
            for category in direct.categories {
                check.expect(
                    storeResult.state(of: category.id, in: january),
                    directResult.state(of: category.id, in: january),
                    category.name
                )
            }
        }

        check.test("stores a split as a parent plus lines, counted once") {
            let budget = try YNABImporter().makeBudget(planCSV: plan, registerCSV: register)
            let container = try EmbersStore.inMemoryContainer()
            let context = ModelContext(container)
            try ImportWriter.write(budget, into: context)

            let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())
            let parents = transactions.filter(\.isSplitParent)
            check.expect(parents.count, 1)
            check.expect(parents.first?.splitLines?.count, 2)
            check.expect(parents.first?.amountMinor, -5_000)

            // The register keeps 6 rows; a split adds a parent on top of its two lines.
            check.expect(transactions.count, 7)

            // Only leaves reach the engine, so the account balance is not double-counted.
            let input = try BudgetInputBuilder.build(from: context)
            check.expect(input.entries.count, 6)
            let cash = try check.unwrap(input.accounts.first { $0.name == "Cash (USD)" })
            let result = BudgetEngine().compute(input, asOf: asOf, through: january)
            check.expect(result.accountBalances[cash.id], 80_000)
        }

        check.test("keeps the credit card's payment category linked to its account") {
            let budget = try YNABImporter().makeBudget(planCSV: plan, registerCSV: register)
            let container = try EmbersStore.inMemoryContainer()
            let context = ModelContext(container)
            try ImportWriter.write(budget, into: context)

            let categories = try context.fetch(FetchDescriptor<BudgetCategoryModel>())
            let payment = try check.unwrap(categories.first { $0.kind == .creditCardPayment })
            check.expect(payment.linkedAccount?.name, "Atlas MasterCard (EGP)")
            check.expect(payment.group?.name, "Credit Card Payments")
            check.expect(payment.group?.isSystemManaged, true)

            let settings = try context.planSettings()
            check.expect(settings.baseCurrencyCode, "USD")
        }

        check.test("records the entered currency, rate and fee on a transaction") {
            let container = try EmbersStore.inMemoryContainer()
            let context = ModelContext(container)
            let account = Account(name: "Dune Bank", type: .checking, currencyCode: "AED")
            context.insert(account)

            let quote = ExchangeRateQuote(
                baseCode: "USD",
                asOf: Date(timeIntervalSince1970: 1_790_000_000),
                providerName: "open.er-api.com",
                rates: ["EGP": 52.070874, "AED": 3.6725]
            )
            let conversion = try CurrencyConverter(baseCurrency: CurrencyRegistry.usd).convert(
                enteredAmount: 100_000,
                from: CurrencyRegistry.currency(forCode: "EGP"),
                accountCurrency: account.currency,
                quote: quote,
                feePercent: 1.5
            )
            let transaction = LedgerTransaction(
                date: Date(),
                amountMinor: Int(conversion.baseAmount),
                account: account,
                conversion: conversion
            )
            context.insert(transaction)
            try context.save()

            let stored = try check.unwrap(try context.fetch(FetchDescriptor<LedgerTransaction>()).first)
            check.expect(stored.amountMinor, 1_949)
            check.expect(stored.conversion?.enteredCurrencyCode, "EGP")
            check.expect(stored.conversion?.enteredAmount, 100_000)
            check.expect(stored.conversion?.feeAmount, 29)
            check.expect(stored.conversion?.feePercent, 1.5)
        }

        // This read back as .cleared for every row once, which made every register look reconciled.
        check.test("stores each cleared status and reads the same one back") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let account = Account(name: "Cash", type: .cash)
            context.insert(account)
            for (index, status) in [ClearedStatus.uncleared, .cleared, .reconciled].enumerated() {
                context.insert(
                    LedgerTransaction(
                        date: .budgetDay(year: 2026, month: 1, day: index + 1),
                        amountMinor: -1_000 * (index + 1), cleared: status, account: account
                    )
                )
            }
            try context.save()

            let stored = try context.fetch(FetchDescriptor<LedgerTransaction>())
                .sorted { $0.date < $1.date }
            check.expect(stored.map(\.cleared), [.uncleared, .cleared, .reconciled])

            stored[0].cleared = .reconciled
            try context.save()
            let reread = try context.fetch(FetchDescriptor<LedgerTransaction>())
                .sorted { $0.date < $1.date }
            check.expect(reread[0].cleared, .reconciled, "a changed status must persist too")
        }

        check.test("caches an exchange rate quote and reads it back") {
            let container = try EmbersStore.inMemoryContainer()
            let context = ModelContext(container)
            let quote = ExchangeRateQuote(
                baseCode: "USD",
                asOf: Date(timeIntervalSince1970: 1_790_000_000),
                providerName: "open.er-api.com",
                rates: ["EGP": 52.070874, "KES": 129.549122]
            )
            context.insert(ExchangeRateSnapshot(quote: quote))
            try context.save()

            let stored = try check.unwrap(try context.fetch(FetchDescriptor<ExchangeRateSnapshot>()).first)
            check.expect(stored.quote.rates["EGP"], 52.070874)
            check.expect(stored.quote.baseCode, "USD")
            check.expect(stored.quote.rate(from: "EGP", to: "USD"), 1 / 52.070874)
        }

        check.test("Start Fresh clears plan data but keeps settings") {
            let budget = try YNABImporter().makeBudget(planCSV: plan, registerCSV: register)
            let container = try EmbersStore.inMemoryContainer()
            let context = ModelContext(container)
            try ImportWriter.write(budget, into: context)
            check.expectTrue(try context.fetch(FetchDescriptor<LedgerTransaction>()).count > 0)

            try ImportWriter.deleteAllPlanData(in: context)
            check.expect(try context.fetch(FetchDescriptor<LedgerTransaction>()).count, 0)
            check.expect(try context.fetch(FetchDescriptor<Account>()).count, 0)
            check.expect(try context.fetch(FetchDescriptor<BudgetCategoryModel>()).count, 0)
            check.expect(try context.fetch(FetchDescriptor<PlanSettings>()).count, 1)
        }
    }
}
