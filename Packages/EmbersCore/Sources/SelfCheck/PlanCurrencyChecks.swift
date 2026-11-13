import Foundation
import EmbersCore
import EmbersData
import SwiftData

/// Choosing the plan's currency, which every stored amount is measured in, and so can only be
/// chosen before there are any.
@MainActor
func planCurrencyChecks(_ check: Checker) {
    let october = YearMonth(year: 2026, month: 10)

    func onDisk() throws -> ModelContext {
        let url = URL.temporaryDirectory.appending(path: "plan-currency-\(UUID().uuidString).store")
        return ModelContext(try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url))
    }

    func reopened(_ context: ModelContext) throws -> ModelContext {
        ModelContext(try EmbersStore.container(cloudKitContainerIdentifier: nil, url: try check.unwrap(context.container.configurations.first?.url)))
    }

    check.suite("Choosing the plan currency") {
        check.test("a new plan offers the region's currency") {
            check.expect(CurrencyRegistry.regionCode(for: Locale(identifier: "ar_EG")), "EGP")
            check.expect(CurrencyRegistry.regionCode(for: Locale(identifier: "ja_JP")), "JPY")
            check.expect(
                CurrencyRegistry.regionCode(for: Locale(identifier: "en")), "USD",
                "a language with no region has no currency of its own"
            )
        }

        check.test("an empty plan takes any currency, and keeps it") {
            let context = try onDisk()
            try CategoryWriter.seedStarterPlan(in: context)
            try AccountWriter.create(name: "Wallet", type: .cash, currencyCode: "USD", in: context)
            check.expectTrue(
                try PlanSettingsWriter.mayChangeBaseCurrency(in: context),
                "starter groups and an account with no balance hold no amount"
            )

            try PlanSettingsWriter.setBaseCurrency("eur", in: context)
            check.expect(try reopened(context).planSettings().baseCurrencyCode, "EUR")
            check.expect(
                try context.fetch(FetchDescriptor<Account>()).first?.currencyCode, "USD",
                "an account's own currency is its own"
            )
        }

        check.test("an unknown code is refused") {
            let context = try onDisk()
            check.expectThrows("not a currency") { try PlanSettingsWriter.setBaseCurrency("NW", in: context) }
            check.expect(try context.planSettings().baseCurrencyCode, "USD")
        }

        check.test("an opening balance fixes it") {
            let context = try onDisk()
            try AccountWriter.create(
                name: "Checking", type: .checking, currencyCode: "USD",
                startingBalanceMinor: 1_234, in: context
            )
            check.expectTrue(!(try PlanSettingsWriter.mayChangeBaseCurrency(in: context)))
            check.expectThrows("$12.34 would read as ¥1234") {
                try PlanSettingsWriter.setBaseCurrency("JPY", in: context)
            }
            check.expect(try reopened(context).planSettings().baseCurrencyCode, "USD")
        }

        check.test("so does an assignment, or a target, with no transaction at all") {
            let assigned = try onDisk()
            try CategoryWriter.seedStarterPlan(in: assigned)
            let groceries = try check.unwrap(try assigned.fetch(FetchDescriptor<BudgetCategoryModel>()).first)
            try AssignmentWriter.adjustAssigned(by: 5_000, category: groceries, month: october, in: assigned)
            check.expectThrows("an assignment is an amount") {
                try PlanSettingsWriter.setBaseCurrency("EUR", in: assigned)
            }

            let targeted = try onDisk()
            try CategoryWriter.seedStarterPlan(in: targeted)
            let rent = try check.unwrap(try targeted.fetch(FetchDescriptor<BudgetCategoryModel>()).first)
            rent.targetKind = .monthlySavingsBuilder
            rent.targetAmountMinor = 150_000
            try targeted.save()
            check.expectThrows("a target is an amount") {
                try PlanSettingsWriter.setBaseCurrency("EUR", in: targeted)
            }
        }

        check.test("choosing the currency it already has is not a change") {
            let context = try onDisk()
            try AccountWriter.create(
                name: "Checking", type: .checking, currencyCode: "USD",
                startingBalanceMinor: 1_234, in: context
            )
            try PlanSettingsWriter.setBaseCurrency("USD", in: context)
        }
    }
}
