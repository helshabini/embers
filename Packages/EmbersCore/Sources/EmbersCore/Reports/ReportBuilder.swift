import Foundation

/// One month's money in and money out.
public struct MonthlyFlow: Sendable, Equatable {
    public var month: YearMonth
    /// Money received into the inflow bucket.
    public var income: MinorUnits
    /// Money spent from categories, net of refunds. Positive means spending.
    public var spending: MinorUnits

    public var net: MinorUnits { income - spending }
}

/// What a category absorbed over a range.
public struct SpendingSlice: Sendable, Equatable {
    public var categoryID: EntityID
    public var name: String
    public var groupName: String
    /// Positive means money spent.
    public var amount: MinorUnits
}

/// Net worth at the end of a month.
public struct NetWorthPoint: Sendable, Equatable {
    public var month: YearMonth
    public var assets: MinorUnits
    /// Negative: what is owed.
    public var liabilities: MinorUnits

    public var net: MinorUnits { assets + liabilities }
}

/// Builds the figures behind the reports.
///
/// Works from the same snapshot the engine consumes rather than from its output, because the answers
/// differ: a card payment moves money into a payment category, which is real budget activity but is
/// not spending, and counting it would double every card purchase.
public enum ReportBuilder {
    /// Income and spending per month, oldest first.
    public static func flows(
        _ input: BudgetInput,
        from start: YearMonth,
        through end: YearMonth,
        asOf: Date? = nil
    ) -> [MonthlyFlow] {
        let categoriesByID = Dictionary(input.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var income: [YearMonth: MinorUnits] = [:]
        var spending: [YearMonth: MinorUnits] = [:]

        for entry in input.entries {
            guard entry.hasHappened(asOf: asOf) else { continue }
            guard let categoryID = entry.categoryID, let category = categoriesByID[categoryID] else { continue }
            let month = YearMonth(containing: entry.date)
            switch category.kind {
            case .inflowReadyToAssign:
                income[month, default: 0] += entry.amount
            case .normal:
                // Refunds net off, so a returned purchase does not read as income.
                spending[month, default: 0] -= entry.amount
            case .creditCardPayment:
                // Money set aside to pay a card is not a second purchase.
                continue
            }
        }

        return YearMonth.range(from: start, through: end).map { month in
            MonthlyFlow(
                month: month,
                income: income[month] ?? 0,
                spending: spending[month] ?? 0
            )
        }
    }

    /// Spending per category over a range, largest first, excluding categories that absorbed nothing.
    public static func spendingByCategory(
        _ input: BudgetInput,
        from start: YearMonth,
        through end: YearMonth,
        asOf: Date? = nil
    ) -> [SpendingSlice] {
        let categoriesByID = Dictionary(input.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var totals: [EntityID: MinorUnits] = [:]

        for entry in input.entries {
            guard entry.hasHappened(asOf: asOf) else { continue }
            guard let categoryID = entry.categoryID,
                  let category = categoriesByID[categoryID],
                  category.kind == .normal
            else { continue }
            let month = YearMonth(containing: entry.date)
            guard month >= start, month <= end else { continue }
            totals[categoryID, default: 0] -= entry.amount
        }

        return totals.compactMap { categoryID, amount -> SpendingSlice? in
            guard amount > 0, let category = categoriesByID[categoryID] else { return nil }
            return SpendingSlice(
                categoryID: categoryID,
                name: category.name,
                groupName: category.groupName,
                amount: amount
            )
        }
        .sorted { $0.amount > $1.amount }
    }

    /// Net worth at the end of each month, oldest first.
    ///
    /// Every account counts, on budget or not: a brokerage balance is part of what you are worth even
    /// though it is not part of what you can assign.
    public static func netWorth(
        _ input: BudgetInput,
        from start: YearMonth,
        through end: YearMonth,
        asOf: Date? = nil
    ) -> [NetWorthPoint] {
        let accountsByID = Dictionary(input.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var assetsByMonth: [YearMonth: MinorUnits] = [:]
        var liabilitiesByMonth: [YearMonth: MinorUnits] = [:]

        for entry in input.entries {
            guard entry.hasHappened(asOf: asOf) else { continue }
            guard let account = accountsByID[entry.accountID] else { continue }
            let month = YearMonth(containing: entry.date)
            if account.type.isLiability {
                liabilitiesByMonth[month, default: 0] += entry.amount
            } else {
                assetsByMonth[month, default: 0] += entry.amount
            }
        }

        // Balances before the range still count towards where it starts.
        var assets: MinorUnits = 0
        var liabilities: MinorUnits = 0
        for (month, amount) in assetsByMonth where month < start { assets += amount }
        for (month, amount) in liabilitiesByMonth where month < start { liabilities += amount }

        return YearMonth.range(from: start, through: end).map { month in
            assets += assetsByMonth[month] ?? 0
            liabilities += liabilitiesByMonth[month] ?? 0
            return NetWorthPoint(month: month, assets: assets, liabilities: liabilities)
        }
    }
}
