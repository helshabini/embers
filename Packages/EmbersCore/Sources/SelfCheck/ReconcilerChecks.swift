import Foundation
import EmbersCore

private let header = """
"Account","Flag","Date","Payee","Category Group/Category","Category Group","Category","Memo","Outflow","Inflow","Cleared"
"""

func reconcilerChecks(_ check: Checker) {
    check.suite("Import reconciliation") {
        // A category whose reported Available cannot be rederived from the register: the export says
        // 50.00, the transactions only account for 30.00.
        let plan = """
        "Month","Category Group/Category","Category Group","Category","Assigned","Activity","Available"
        "Jan 2026","Immediate Obligations: Groceries","Immediate Obligations","Groceries",$100.00,-$70.00,$50.00
        """
        let register = """
        \(header)
        "Cash (USD)","","01/05/2026","Paycheck","Inflow: Ready to Assign","Inflow","Ready to Assign","",$0.00,$500.00,"Cleared"
        "Cash (USD)","","01/10/2026","Carreta Market","Immediate Obligations: Groceries","Immediate Obligations","Groceries","",$70.00,$0.00,"Cleared"
        """
        let asOf = Calendar.gregorianUTC.date(
            from: DateComponents(year: 2026, month: 1, day: 31, hour: 23)
        )!
        let january = YearMonth(year: 2026, month: 1)

        check.test("detects a category whose reported balance cannot be rederived") {
            let budget = try YNABImporter().makeBudget(planCSV: plan, registerCSV: register)
            let outcome = BudgetReconciler().reconcile(budget, at: january, asOf: asOf)
            check.expect(outcome.adjustments.count, 1)
            let adjustment = try check.unwrap(outcome.adjustments.first)
            check.expect(adjustment.categoryName, "Groceries")
            check.expect(adjustment.reportedAvailable, 5_000)
            check.expect(adjustment.computedAvailable, 3_000)
            check.expect(adjustment.amount, 2_000)
            check.expect(outcome.totalAmount, 2_000)
        }

        check.test("adjusting brings the closing balance onto the reported one") {
            let budget = try YNABImporter().makeBudget(planCSV: plan, registerCSV: register)
            let (adjusted, outcome) = BudgetReconciler().reconciled(budget, at: january, asOf: asOf)
            check.expect(adjusted.assignments.count, budget.assignments.count + 1)

            let result = BudgetEngine().compute(adjusted.budgetInput(), asOf: asOf, through: january)
            let categoryID = try check.unwrap(outcome.adjustments.first?.categoryID)
            check.expect(result.state(of: categoryID, in: january).available, 5_000)

            // A second pass finds nothing left to do.
            let again = BudgetReconciler().reconcile(adjusted, at: january, asOf: asOf)
            check.expectTrue(again.isClean, "second pass should be clean")
        }

        check.test("leaves transactions and account balances untouched") {
            let budget = try YNABImporter().makeBudget(planCSV: plan, registerCSV: register)
            let (adjusted, _) = BudgetReconciler().reconciled(budget, at: january, asOf: asOf)
            check.expect(adjusted.transactions.count, budget.transactions.count)

            let before = BudgetEngine().compute(budget.budgetInput(), asOf: asOf, through: january)
            let after = BudgetEngine().compute(adjusted.budgetInput(), asOf: asOf, through: january)
            check.expect(after.accountBalances, before.accountBalances)
            check.expect(after.netWorth, before.netWorth)
        }

        check.test("reports nothing to do when the budget already agrees") {
            let matching = """
            "Month","Category Group/Category","Category Group","Category","Assigned","Activity","Available"
            "Jan 2026","Immediate Obligations: Groceries","Immediate Obligations","Groceries",$100.00,-$70.00,$30.00
            """
            let budget = try YNABImporter().makeBudget(planCSV: matching, registerCSV: register)
            let outcome = BudgetReconciler().reconcile(budget, at: january, asOf: asOf)
            check.expectTrue(outcome.isClean, "adjustments: \(outcome.adjustments.count)")
        }
    }
}
