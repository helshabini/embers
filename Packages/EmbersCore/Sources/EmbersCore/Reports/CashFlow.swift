import Foundation

/// Where a range's income came from and where it went: the figures behind the cash-flow diagram.
///
/// Both sides add up to the same total — the larger of income and spending — so the diagram's
/// columns are all one height. What income left over is `saved`; what spending took beyond income
/// came out of money already there, `fromSavings`.
public struct CashFlow: Sendable, Equatable {
    /// A box in the diagram. One standing for several that were too small to draw has a `foldedCount`.
    public struct Node: Sendable, Equatable {
        /// Nil for a folded node, and for the entries with no payee.
        public var key: SpendingKey?
        /// As stored; empty for a folded node and for no payee.
        public var name: String
        public var amount: MinorUnits
        /// How many it stands for, when it stands for several. Zero for one.
        public var foldedCount: Int
        public var children: [Node]

        public init(key: SpendingKey?, name: String, amount: MinorUnits, foldedCount: Int = 0, children: [Node] = []) {
            self.key = key
            self.name = name
            self.amount = amount
            self.foldedCount = foldedCount
            self.children = children
        }
    }

    /// Who paid in, largest first.
    public var sources: [Node]
    /// Groups, largest first, each with its categories.
    public var groups: [Node]
    public var income: MinorUnits
    public var spending: MinorUnits

    public var saved: MinorUnits { max(income - spending, 0) }
    public var fromSavings: MinorUnits { max(spending - income, 0) }
    /// The height of every column.
    public var total: MinorUnits { max(income, spending) }
    public var isEmpty: Bool { total == 0 }
}

extension ReportBuilder {
    /// Income by payer, and spending by group and category, over a range.
    ///
    /// Each payer and each category is netted on its own and kept only if it comes out positive, the
    /// way the spending breakdown keeps them, so a refunded purchase does not appear as a sliver of
    /// negative width. The totals are the sums of what is drawn, so the columns always meet.
    ///
    /// - Parameters:
    ///   - sourceLimit, groupLimit, categoryLimit: how many are drawn on their own before the rest
    ///     are folded into one. A diagram of forty ribbons is a texture, not a picture.
    public static func cashFlow(
        _ input: BudgetInput,
        from start: YearMonth,
        through end: YearMonth,
        asOf: Date? = nil,
        sourceLimit: Int = 5,
        groupLimit: Int = 6,
        categoryLimit: Int = 4
    ) -> CashFlow {
        let categoriesByID = Dictionary(input.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var byPayer: [SpendingKey: MinorUnits] = [:]
        for entry in input.entries {
            guard entry.hasHappened(asOf: asOf),
                  let categoryID = entry.categoryID,
                  categoriesByID[categoryID]?.kind == .inflowReadyToAssign
            else { continue }
            let month = YearMonth(containing: entry.date)
            guard month >= start, month <= end else { continue }
            byPayer[payeeKey(of: entry), default: 0] += entry.amount
        }
        let payers = byPayer.filter { $0.value > 0 }
            .map { key, amount in
                CashFlow.Node(
                    key: key,
                    name: name(of: key, in: input),
                    amount: amount,
                    foldedCount: 0,
                    children: []
                )
            }
            .sorted { ($0.amount, $1.name) > ($1.amount, $0.name) }

        let categories = spending(input, from: start, through: end, asOf: asOf, by: .category)
        let groups = Dictionary(grouping: categories, by: { $0.groupName ?? "" })
            .map { groupName, shares in
                CashFlow.Node(
                    key: .group(groupName),
                    name: groupName,
                    amount: shares.reduce(0) { $0 + $1.amount },
                    foldedCount: 0,
                    children: folded(
                        shares.map { CashFlow.Node(key: $0.key, name: $0.name, amount: $0.amount, foldedCount: 0, children: []) },
                        keeping: categoryLimit
                    )
                )
            }
            .sorted { ($0.amount, $1.name) > ($1.amount, $0.name) }

        return CashFlow(
            sources: folded(payers, keeping: sourceLimit),
            groups: folded(groups, keeping: groupLimit),
            income: payers.reduce(0) { $0 + $1.amount },
            spending: groups.reduce(0) { $0 + $1.amount }
        )
    }

    /// The first `limit` as they are, and the rest as one. Folding a single one would only hide its
    /// name, so it is kept.
    private static func folded(_ nodes: [CashFlow.Node], keeping limit: Int) -> [CashFlow.Node] {
        guard nodes.count > limit + 1 else { return nodes }
        let rest = nodes.dropFirst(limit)
        return Array(nodes.prefix(limit)) + [CashFlow.Node(
            key: nil,
            name: "",
            amount: rest.reduce(0) { $0 + $1.amount },
            foldedCount: rest.count,
            children: []
        )]
    }
}
