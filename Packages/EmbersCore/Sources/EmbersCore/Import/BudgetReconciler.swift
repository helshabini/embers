import Foundation

/// Closes the gap between an imported budget's computed state and the balances the source reported.
///
/// A YNAB export states what each category's Available *was*, but some of YNAB's internal
/// credit-card movements cannot be rederived from the register alone. Rather than edit transactions —
/// which would corrupt account balances, spending history, and every report — the difference is
/// recorded as an ordinary assignment in the closing month. Assignments are exactly "money moved
/// into or out of a category", so the adjustment is visible and reversible in the Plan screen, and
/// the ledger itself stays untouched.
public struct BudgetReconciler: Sendable {
    public struct Adjustment: Sendable {
        public var categoryID: EntityID
        public var groupName: String
        public var categoryName: String
        public var month: YearMonth
        public var reportedAvailable: MinorUnits
        public var computedAvailable: MinorUnits
        /// The assignment to record so the computed balance lands on the reported one.
        public var amount: MinorUnits
    }

    public struct Outcome: Sendable {
        public var adjustments: [Adjustment] = []
        public var month: YearMonth
        public var totalAmount: MinorUnits {
            adjustments.reduce(0) { $0 + $1.amount }
        }
        public var isClean: Bool { adjustments.isEmpty }
    }

    public init() {}

    /// Compares the engine's closing month against the source's reported balances.
    ///
    /// - Parameter month: The closing month to align, normally the last month the export covers.
    public func reconcile(
        _ budget: ImportedBudget,
        at month: YearMonth,
        asOf: Date? = nil
    ) -> Outcome {
        let result = BudgetEngine().compute(budget.budgetInput(), asOf: asOf, through: month)
        var outcome = Outcome(month: month)

        for expectation in budget.expectations where expectation.month == month {
            guard let categoryID = expectation.categoryID else { continue }
            let computed = result.state(of: categoryID, in: month).available
            guard computed != expectation.available else { continue }
            outcome.adjustments.append(
                Adjustment(
                    categoryID: categoryID,
                    groupName: expectation.groupName,
                    categoryName: expectation.categoryName,
                    month: month,
                    reportedAvailable: expectation.available,
                    computedAvailable: computed,
                    amount: expectation.available - computed
                )
            )
        }

        return outcome
    }

    /// Reconciles and returns the budget with the adjusting assignments folded in.
    public func reconciled(
        _ budget: ImportedBudget,
        at month: YearMonth,
        asOf: Date? = nil
    ) -> (budget: ImportedBudget, outcome: Outcome) {
        let outcome = reconcile(budget, at: month, asOf: asOf)
        guard !outcome.isClean else { return (budget, outcome) }

        var adjusted = budget
        adjusted.assignments += outcome.adjustments.map {
            ImportedAssignment(categoryID: $0.categoryID, month: $0.month, amount: $0.amount)
        }
        adjusted.report.warnings.append(
            "Reconciled \(outcome.adjustments.count) categories to the export's closing balances."
        )
        return (adjusted, outcome)
    }
}
