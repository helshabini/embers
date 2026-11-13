import Foundation

/// What spending can be broken down by.
public enum SpendingDimension: String, CaseIterable, Sendable {
    case category
    case group
    case payee
}

/// One thing spending can be narrowed to. Several together narrow to what matches all of them, which
/// is how a report drills from a group to a category in it, and from there to one payee.
public enum SpendingKey: Hashable, Sendable {
    case category(EntityID)
    case group(String)
    /// Nil is the entries with no payee, which are a share of their own rather than nobody's.
    case payee(EntityID?)
    /// Money that left the budget by transfer — a mortgage paid into a tracked property — has no
    /// payee, and is named after the account it went to, as the register names it.
    case transfer(to: EntityID)

    public var dimension: SpendingDimension {
        switch self {
        case .category: .category
        case .group: .group
        case .payee, .transfer: .payee
        }
    }

    func matches(_ entry: BudgetEntry, in category: BudgetCategory) -> Bool {
        switch self {
        case let .category(id): category.id == id
        case let .group(name): category.groupName == name
        case let .payee(id): entry.payeeID == id && (id != nil || entry.transferCounterAccountID == nil)
        case let .transfer(account): entry.payeeID == nil && entry.transferCounterAccountID == account
        }
    }
}

/// What one category, group or payee absorbed over a range.
public struct SpendingShare: Sendable, Equatable {
    public var key: SpendingKey
    /// As stored: a provided category or group name is translated by whoever shows it. Empty for the
    /// entries with no payee.
    public var name: String
    /// A category's group, for telling two of the same name apart.
    public var groupName: String?
    /// Positive means money spent.
    public var amount: MinorUnits
}

/// One month's spending, for a trend.
public struct MonthlyAmount: Sendable, Equatable {
    public var month: YearMonth
    public var amount: MinorUnits
}

extension ReportBuilder {
    /// The entries that count as spending in a range: happened, in an ordinary category, and matching
    /// every key given. Card payment categories are left out for the reason `flows` gives.
    public static func spendingEntries(
        _ input: BudgetInput,
        from start: YearMonth,
        through end: YearMonth,
        asOf: Date? = nil,
        matching keys: [SpendingKey] = []
    ) -> [(entry: BudgetEntry, category: BudgetCategory)] {
        let categoriesByID = Dictionary(input.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return input.entries.compactMap { entry in
            guard entry.hasHappened(asOf: asOf),
                  let categoryID = entry.categoryID,
                  let category = categoriesByID[categoryID],
                  category.kind == .normal
            else { return nil }
            let month = YearMonth(containing: entry.date)
            guard month >= start, month <= end else { return nil }
            guard keys.allSatisfy({ $0.matches(entry, in: category) }) else { return nil }
            return (entry, category)
        }
    }

    /// Spending broken down by one dimension, largest first.
    ///
    /// Refunds net off within each share, and a share that took in more than it spent is left out
    /// rather than shown as negative spending — as `spendingByCategory` does.
    public static func spending(
        _ input: BudgetInput,
        from start: YearMonth,
        through end: YearMonth,
        asOf: Date? = nil,
        by dimension: SpendingDimension,
        matching keys: [SpendingKey] = []
    ) -> [SpendingShare] {
        var totals: [SpendingKey: MinorUnits] = [:]
        var named: [SpendingKey: (name: String, group: String?)] = [:]
        for (entry, category) in spendingEntries(input, from: start, through: end, asOf: asOf, matching: keys) {
            let key: SpendingKey
            switch dimension {
            case .category:
                key = .category(category.id)
                named[key] = (category.name, category.groupName)
            case .group:
                key = .group(category.groupName)
                named[key] = (category.groupName, nil)
            case .payee:
                key = payeeKey(of: entry)
                named[key] = (name(of: key, in: input), nil)
            }
            totals[key, default: 0] -= entry.amount
        }
        return totals.compactMap { key, amount -> SpendingShare? in
            guard amount > 0, let name = named[key] else { return nil }
            return SpendingShare(key: key, name: name.name, groupName: name.group, amount: amount)
        }
        // Equal amounts in name order, so the list does not reshuffle between two builds.
        .sorted { ($0.amount, $1.name) > ($1.amount, $0.name) }
    }

    /// Who an entry was paid to, or for a transfer with no payee, where it went.
    static func payeeKey(of entry: BudgetEntry) -> SpendingKey {
        if entry.payeeID == nil, let account = entry.transferCounterAccountID { return .transfer(to: account) }
        return .payee(entry.payeeID)
    }

    /// A payee's or an account's stored name; empty for no payee at all.
    static func name(of key: SpendingKey, in input: BudgetInput) -> String {
        switch key {
        case let .payee(id): id.flatMap { input.payeeNames[$0] } ?? ""
        case let .transfer(account): input.accounts.first { $0.id == account }?.name ?? ""
        case .category, .group: ""
        }
    }

    /// What was spent each month on whatever the keys narrow to, oldest first. A month that took in
    /// more than it spent is negative here: a trend has to show it.
    public static func monthlySpending(
        _ input: BudgetInput,
        from start: YearMonth,
        through end: YearMonth,
        asOf: Date? = nil,
        matching keys: [SpendingKey] = []
    ) -> [MonthlyAmount] {
        var byMonth: [YearMonth: MinorUnits] = [:]
        for (entry, _) in spendingEntries(input, from: start, through: end, asOf: asOf, matching: keys) {
            byMonth[YearMonth(containing: entry.date), default: 0] -= entry.amount
        }
        return YearMonth.range(from: start, through: end).map {
            MonthlyAmount(month: $0, amount: byMonth[$0] ?? 0)
        }
    }
}
