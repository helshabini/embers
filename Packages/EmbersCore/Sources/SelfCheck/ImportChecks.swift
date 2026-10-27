import Foundation
import EmbersCore

private let header = """
"Account","Flag","Date","Payee","Category Group/Category","Category Group","Category","Memo","Outflow","Inflow","Cleared"
"""

private let emptyPlan = """
"Month","Category Group/Category","Category Group","Category","Assigned","Activity","Available"
"""

func importChecks(_ check: Checker) {
    check.suite("YNAB importer") {
        // Mirrors the real export's Summit Checking 5-line split: the lines disagree on payee and three
        // of them are transfers, so grouping cannot key on the payee.
        check.test("groups split lines that disagree on payee") {
            let register = """
            \(header)
            "Summit Checking (USD)","","08/26/2019","Transfer : Lending","Debt Payments: Personal Loan","Debt Payments","Personal Loan","Split (1/5) Family Loan",$3900.00,$0.00,"Reconciled"
            "Summit Checking (USD)","","08/26/2019","Sam","True Expenses: Schooling","True Expenses","Schooling","Split (2/5)",$3600.00,$0.00,"Reconciled"
            "Summit Checking (USD)","","08/26/2019","Transfer : Atlas Savings (USD)","","","","Split (3/5)",$350.00,$0.00,"Reconciled"
            "Summit Checking (USD)","","08/26/2019","Transfer : Atlas Savings (EGP)","","","","Split (4/5)",$554.21,$0.00,"Reconciled"
            "Summit Checking (USD)","","08/26/2019","Sam","Immediate Obligations: Household","Immediate Obligations","Household","Split (5/5)",$595.79,$0.00,"Reconciled"
            "Atlas Savings (USD)","","08/26/2019","Transfer : Summit Checking (USD)","","","","",$0.00,$350.00,"Reconciled"
            """
            let budget = try YNABImporter().makeBudget(planCSV: emptyPlan, registerCSV: register)

            let splits = budget.transactions.filter(\.isSplit)
            check.expect(splits.count, 1)
            let split = try check.unwrap(splits.first)
            check.expect(split.splits.count, 5)
            check.expect(split.amount, -900_000)
            // The parent takes a real payee, not a transfer marker.
            check.expect(split.payeeName, "Sam")
            check.expect(split.splits[0].payeeName, "Transfer : Lending")
            check.expectTrue(split.splits[2].transferCounterAccountID != nil, "line 3 is a transfer")
            check.expectNil(split.splits[1].transferCounterAccountID, "line 2 is not a transfer")
            // The fixture deliberately omits some transfer counterparts; only split warnings matter.
            check.expectTrue(
                !budget.report.warnings.contains { $0.contains("Split") },
                "split warnings: \(budget.report.warnings)"
            )
        }

        check.test("separates two splits sharing an account, date, and line count") {
            let register = """
            \(header)
            "Cash (EGP)","","01/10/2021","PayLink","Just for Fun: Fun Money","Just for Fun","Fun Money","Split (1/2)",$10.00,$0.00,"Cleared"
            "Cash (EGP)","","01/10/2021","PayLink","Immediate Obligations: Transportation","Immediate Obligations","Transportation","Split (2/2)",$20.00,$0.00,"Cleared"
            "Cash (EGP)","","01/10/2021","Stride Sports","True Expenses: Clothing","True Expenses","Clothing","Split (1/2)",$30.00,$0.00,"Cleared"
            "Cash (EGP)","","01/10/2021","Stride Sports","Just for Fun: Dining Out","Just for Fun","Dining Out","Split (2/2)",$40.00,$0.00,"Cleared"
            """
            let budget = try YNABImporter().makeBudget(planCSV: emptyPlan, registerCSV: register)
            let splits = budget.transactions.filter(\.isSplit)
            check.expect(splits.count, 2)
            check.expect(Set(splits.map(\.amount)), [-3000, -7000])
        }

        // The counter side of a split's transfer line inherits the "Split (i/n)" memo, but a single
        // line is not a split.
        check.test("treats a lone split-marked row as a plain transaction") {
            let register = """
            \(header)
            "Atlas Savings (USD)","","08/26/2019","Transfer : Summit Checking (USD)","","","","Split (3/5)",$0.00,$350.00,"Reconciled"
            """
            let budget = try YNABImporter().makeBudget(planCSV: emptyPlan, registerCSV: register)
            check.expect(budget.transactions.count, 1)
            check.expect(budget.transactions[0].isSplit, false)
            check.expect(budget.transactions[0].memo, "")
            check.expectTrue(
                !budget.report.warnings.contains { $0.contains("Split") },
                "split warnings: \(budget.report.warnings)"
            )
        }

        check.test("promotes a memo shared by every split line to the parent") {
            let register = """
            \(header)
            "Cash (USD)","","01/10/2021","Apple","True Expenses: Tech","True Expenses","Tech","Split (1/2) iPad & Accessories",$10.00,$0.00,"Cleared"
            "Cash (USD)","","01/10/2021","Apple","Just for Fun: Fun Money","Just for Fun","Fun Money","Split (2/2) iPad & Accessories",$20.00,$0.00,"Cleared"
            """
            let budget = try YNABImporter().makeBudget(planCSV: emptyPlan, registerCSV: register)
            let split = try check.unwrap(budget.transactions.first(where: \.isSplit))
            check.expect(split.memo, "iPad & Accessories")
            check.expectTrue(split.splits.allSatisfy { $0.memo.isEmpty })
        }

        check.test("identifies credit cards, closed cards, and tracking accounts") {
            let plan = """
            "Month","Category Group/Category","Category Group","Category","Assigned","Activity","Available"
            "Aug 2019","Credit Card Payments: Atlas MasterCard (EGP)","Credit Card Payments","Atlas MasterCard (EGP)",$0.00,$0.00,$0.00
            "Aug 2019","Hidden Categories: Atlas Visa (EGP)","Hidden Categories","Atlas Visa (EGP)",$0.00,$0.00,$0.00
            "Aug 2019","Immediate Obligations: Groceries","Immediate Obligations","Groceries",$0.00,$0.00,$0.00
            """
            let register = """
            \(header)
            "Atlas MasterCard (EGP)","","08/19/2019","Carreta Market","Immediate Obligations: Groceries","Immediate Obligations","Groceries","",$203.40,$0.00,"Reconciled"
            "Atlas Visa (EGP)","","08/19/2019","Carreta Market","Immediate Obligations: Groceries","Immediate Obligations","Groceries","",$10.00,$0.00,"Reconciled"
            "Cash (EGP)","","08/19/2019","Carreta Market","Immediate Obligations: Groceries","Immediate Obligations","Groceries","",$5.00,$0.00,"Reconciled"
            "Crypto","","08/19/2019","Starting Balance","","","","",$0.00,$100.00,"Reconciled"
            """
            let budget = try YNABImporter().makeBudget(planCSV: plan, registerCSV: register)

            func account(_ name: String) throws -> ImportedAccount {
                try check.unwrap(budget.accounts.first { $0.name == name }, name)
            }
            check.expect(try account("Atlas MasterCard (EGP)").type, .creditCard)
            check.expect(try account("Atlas MasterCard (EGP)").currencyCode, "EGP")
            check.expect(try account("Atlas MasterCard (EGP)").closed, false)
            // A payment category parked in Hidden Categories means the card is closed.
            check.expect(try account("Atlas Visa (EGP)").type, .creditCard)
            check.expect(try account("Atlas Visa (EGP)").closed, true)
            check.expect(try account("Cash (EGP)").type, .cash)
            // No categorised transactions, so it is a tracking account.
            check.expect(try account("Crypto").type, .investment)
            check.expect(try account("Crypto").onBudget, false)

            let paymentCategories = budget.categories.filter { $0.kind == .creditCardPayment }
            check.expect(paymentCategories.count, 2)
            check.expectTrue(paymentCategories.allSatisfy { $0.linkedAccountID != nil })
        }

        check.test("treats transfer payees as links, not payees") {
            let register = """
            \(header)
            "Cash (USD)","","01/10/2021","Transfer : Cash (EGP)","","","","",$50.00,$0.00,"Cleared"
            "Cash (EGP)","","01/10/2021","Transfer : Cash (USD)","","","","",$0.00,$50.00,"Cleared"
            "Cash (USD)","","01/11/2021","Carreta Market","","","","",$5.00,$0.00,"Cleared"
            """
            let budget = try YNABImporter().makeBudget(planCSV: emptyPlan, registerCSV: register)
            check.expect(budget.payees.map(\.name), ["Carreta Market"])
            check.expect(budget.report.transferPairCount, 1)
            check.expect(budget.report.unmatchedTransferCount, 0)
            check.expect(budget.transactions.filter { $0.transferCounterAccountID != nil }.count, 2)
        }

        check.test("imports assignments and keeps plan rows as expectations") {
            let plan = """
            "Month","Category Group/Category","Category Group","Category","Assigned","Activity","Available"
            "Aug 2019","Immediate Obligations: Groceries","Immediate Obligations","Groceries",$300.00,-$100.00,$200.00
            "Sep 2019","Immediate Obligations: Groceries","Immediate Obligations","Groceries",$0.00,$0.00,$200.00
            """
            let budget = try YNABImporter().makeBudget(planCSV: plan, registerCSV: header)
            check.expect(budget.assignments.count, 1)
            check.expect(budget.assignments[0].amount, 30_000)
            check.expect(budget.assignments[0].month, YearMonth(year: 2019, month: 8))
            check.expect(budget.expectations.count, 2)
            check.expect(budget.expectations[0].available, 20_000)
            check.expectTrue(budget.expectations[0].categoryID != nil)
        }
    }
}
