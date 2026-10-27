import Foundation

public struct CategoryMonthState: Hashable, Sendable {
    /// Money moved into the envelope this month.
    public var assigned: MinorUnits = 0
    /// Sum of transactions hitting the envelope this month (outflows negative).
    public var activity: MinorUnits = 0
    /// Balance brought in from the previous month after the overspending rules.
    public var carriedIn: MinorUnits = 0

    public init(assigned: MinorUnits = 0, activity: MinorUnits = 0, carriedIn: MinorUnits = 0) {
        self.assigned = assigned
        self.activity = activity
        self.carriedIn = carriedIn
    }

    /// The part of an overspend that was charged to a card. It became debt rather than coming out of
    /// next month, which is why YNAB shows it orange rather than red.
    public var creditOverspending: MinorUnits = 0

    public var available: MinorUnits { carriedIn + assigned + activity }
    public var isOverspent: Bool { available < 0 }
}

public struct MonthState: Sendable {
    public var month: YearMonth
    public var categories: [EntityID: CategoryMonthState] = [:]
    /// Unassigned money available to budget in this month.
    public var readyToAssign: MinorUnits = 0
    public var assignedTotal: MinorUnits = 0
    public var activityTotal: MinorUnits = 0
    /// Money received into the inflow category this month.
    public var inflowTotal: MinorUnits = 0
    /// Ready to Assign before it is capped at the cash that existed and floored at zero. Kept so the
    /// difference between "nothing left" and "assigned more than exists" stays visible.
    public var uncappedReadyToAssign: MinorUnits = 0
    /// Assigned to months after this one, and already off this month's Ready to Assign.
    public var assignedInFuture: MinorUnits = 0
    /// Everything the on-budget accounts hold at the end of this month, credit balances included.
    public var onBudgetFunds: MinorUnits = 0
    /// What the envelopes actually hold: the positive balances only. A negative balance is a
    /// shortfall to make good, not money available to assign elsewhere.
    public var envelopesHold: MinorUnits = 0
    /// Overspending funded by cash, deducted from the next month's Ready to Assign.
    public var cashOverspending: MinorUnits = 0
    /// Card spending this month that no category had funds to cover: it raised debt instead.
    public var creditOverspending: MinorUnits = 0
    /// Card debt this month's payment categories were short of covering.
    public var unfundedCardDebt: MinorUnits = 0

    public func state(of categoryID: EntityID) -> CategoryMonthState {
        categories[categoryID] ?? CategoryMonthState()
    }
}

public struct BudgetResult: Sendable {
    public var months: [YearMonth: MonthState]
    public var monthsInOrder: [YearMonth]
    /// Working balance per account: what the account holds today, in base currency minor units.
    ///
    /// Entries dated after the cutoff are excluded, matching how the budget counts activity. A
    /// mortgage payment scheduled for next May is not money already gone.
    public var accountBalances: [EntityID: MinorUnits]
    /// Entries dated after the cutoff, per account, kept separately so the register can show what is
    /// coming without letting it distort today's balance.
    public var upcomingByAccount: [EntityID: MinorUnits]
    /// Entries in a budget account that have happened but carry no category, oldest first. Their
    /// money has left (or arrived in) an account without coming out of any envelope or Ready to
    /// Assign, so the plan cannot see it — which is how Ready to Assign and the accounts drift apart
    /// with every envelope covered. Transfers are not here: a move between budget accounts needs no
    /// category, and one across the boundary is the audit's to report.
    public var uncategorized: [EntityID] = []
    /// What is entered but has not happened yet, per spending category and month. Outflows are
    /// negative. Kept apart from activity: a payment due next week is not spent, but the category
    /// should already hold the money for it.
    public var upcomingByCategory: [EntityID: [YearMonth: MinorUnits]] = [:]

    public func upcoming(of categoryID: EntityID, in month: YearMonth) -> MinorUnits {
        upcomingByCategory[categoryID]?[month] ?? 0
    }

    public func state(of categoryID: EntityID, in month: YearMonth) -> CategoryMonthState {
        months[month]?.state(of: categoryID) ?? CategoryMonthState()
    }

    public func readyToAssign(in month: YearMonth) -> MinorUnits {
        months[month]?.readyToAssign ?? 0
    }

    public func upcoming(for accountID: EntityID) -> MinorUnits {
        upcomingByAccount[accountID] ?? 0
    }

    /// What the account will hold once everything already entered has come due.
    public func projectedBalance(of accountID: EntityID) -> MinorUnits {
        (accountBalances[accountID] ?? 0) + upcoming(for: accountID)
    }

    public var netWorth: MinorUnits {
        accountBalances.values.reduce(0, +)
    }
}

/// Computes envelope-budget state from a flat set of accounts, categories, entries, and assignments.
///
/// The rules follow YNAB's, verified by `validate-import` against a real YNAB export:
///
/// - `available = carriedIn + assigned + activity`.
/// - A positive `available` carries into the next month; a negative one resets to zero.
/// - Overspending that was paid with cash is deducted from the *next* month's Ready to Assign.
///   Overspending charged to a credit card is not, nor is a payment category left short: both are
///   debt carried on the card rather than cash already spent.
/// - `readyToAssign(m) = Σ inflow(≤m) − Σ assigned(≤m) − Σ cashOverspending(<m)`.
/// - Spending on a credit card moves money out of the spending category and into that card's payment
///   category, **capped by the funds the category actually has at that moment**. Charging $88.80 to a
///   category holding $35.96 moves only $35.96; the remaining $52.84 is credit overspending.
/// - Paying a card from another budget account moves money back out of its payment category, which
///   may leave that category negative.
/// - A payment category left negative clears to zero, except as far as its card is in credit: that
///   part carries forward, because the card holds the money and later charges will use it up.
/// - A credit on a card that reaches Ready to Assign leaves the card's payment category too, so the
///   same money is not counted both as income and as cash set aside for the debt it paid.
///
/// The last two depart from what YNAB's export shows month by month, and match its closing balances
/// exactly where the plain rules did not (docs/budget-engine/credit-cards.md).
public struct BudgetEngine: Sendable {
    public init() {}

    private struct CategoryMonthKey: Hashable {
        var category: EntityID
        var month: YearMonth
    }

    /// - Parameter asOf: Entries dated after this are treated as upcoming: they still count towards
    ///   account balances, but not towards category activity, inflow, or Ready to Assign. A future
    ///   scheduled payment should not reduce what a category has available today. Pass nil to count
    ///   everything.
    /// - Parameter through: The last month to compute. Months carry balances forward, so the result
    ///   must cover every month the caller can navigate to, not just those with data. Defaults to the
    ///   current month.
    public func compute(
        _ input: BudgetInput,
        asOf: Date? = nil,
        through: YearMonth? = nil
    ) -> BudgetResult {
        // Not `uniqueKeysWithValues`: a synced store can hold one identifier twice until it is merged,
        // and a Mac that downloaded one stopped on it at every launch.
        let accountsByID = Dictionary(input.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let categoriesByID = Dictionary(input.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var paymentCategoryByAccount: [EntityID: EntityID] = [:]
        for category in input.categories where category.kind == .creditCardPayment {
            if let accountID = category.linkedAccountID { paymentCategoryByAccount[accountID] = category.id }
        }

        var entriesByKey: [CategoryMonthKey: [BudgetEntry]] = [:]
        var inflowByMonth: [YearMonth: MinorUnits] = [:]
        var cardPaymentsByKey: [CategoryMonthKey: MinorUnits] = [:]
        var accountBalances: [EntityID: MinorUnits] = [:]
        var upcomingByAccount: [EntityID: MinorUnits] = [:]
        var onBudgetByMonth: [YearMonth: MinorUnits] = [:]
        /// What each budgeted card's balance moved by in each month, for knowing when it is in credit.
        var cardMovementByMonth: [EntityID: [YearMonth: MinorUnits]] = [:]
        /// Uncategorised money moving between a budget account and a tracked one.
        var boundaryFlowByMonth: [YearMonth: MinorUnits] = [:]
        var uncategorized: [BudgetEntry] = []
        var upcomingByCategory: [EntityID: [YearMonth: MinorUnits]] = [:]
        var touchedMonths = Set<YearMonth>()

        for entry in input.entries {
            let month = YearMonth(containing: entry.date)
            touchedMonths.insert(month)

            // Awaiting approval is upcoming whatever its date: it has not happened until someone says so.
            if !entry.hasHappened(asOf: asOf) {
                upcomingByAccount[entry.accountID, default: 0] += entry.amount
                if accountsByID[entry.accountID]?.onBudget == true, let categoryID = entry.categoryID,
                   categoriesByID[categoryID]?.kind == .normal {
                    upcomingByCategory[categoryID, default: [:]][month, default: 0] += entry.amount
                }
                continue
            }
            accountBalances[entry.accountID, default: 0] += entry.amount
            if let account = accountsByID[entry.accountID], account.onBudget {
                onBudgetByMonth[month, default: 0] += entry.amount
                if account.type.isCredit {
                    cardMovementByMonth[account.id, default: [:]][month, default: 0] += entry.amount
                }
            }
            // A credit arriving on a card that the budget counts as new money — filed under Ready to
            // Assign, or arriving uncategorised from outside the budget — lowers what the card owes.
            // The payment category was holding cash for that debt, so it must give the same amount
            // up; otherwise the credit is counted twice, once in Ready to Assign and again as cash
            // set aside for a payment that will never be needed. The real budget's Meridian card kept
            // $52.84 that way from a 2020 credit, with nothing on the card left to pay.
            let creditToCard = paymentCategoryByAccount[entry.accountID].flatMap { paymentCategoryID in
                accountsByID[entry.accountID].flatMap { account in
                    account.onBudget && account.type.isCredit && entry.amount > 0 ? paymentCategoryID : nil
                }
            }

            // A category on a row in a tracked account is not the budget's business: that account is
            // outside the plan. It matters most for a transfer across the edge, where the category
            // belongs to the side inside the budget — counted on both, the same movement arrives and
            // leaves at once and cancels to nothing.
            let insideTheBudget = accountsByID[entry.accountID]?.onBudget ?? false

            guard insideTheBudget, let categoryID = entry.categoryID,
                  let category = categoriesByID[categoryID]
            else {
                if let paymentCategoryID = paymentCategoryByAccount[entry.accountID],
                   isPaymentToCard(entry, accounts: accountsByID) {
                    let key = CategoryMonthKey(category: paymentCategoryID, month: month)
                    cardPaymentsByKey[key, default: 0] += -entry.amount
                }
                // Money crossing the edge of the budget with no category on it. Normally a transfer
                // to a tracking account is categorised spending — a mortgage payment into a tracked
                // apartment — and the category accounts for it. Without one, the money has simply
                // entered or left the budget: it is not spending, and the only honest place for it
                // is what there is left to assign.
                if crossesBudgetBoundary(entry, accounts: accountsByID) {
                    boundaryFlowByMonth[month, default: 0] += entry.amount
                    if let creditToCard {
                        cardPaymentsByKey[CategoryMonthKey(category: creditToCard, month: month), default: 0] += -entry.amount
                    }
                }
                if insideTheBudget, !entry.isTransfer {
                    uncategorized.append(entry)
                }
                continue
            }

            if category.kind == .inflowReadyToAssign {
                inflowByMonth[month, default: 0] += entry.amount
                if let creditToCard {
                    cardPaymentsByKey[CategoryMonthKey(category: creditToCard, month: month), default: 0] += -entry.amount
                }
                continue
            }

            entriesByKey[CategoryMonthKey(category: categoryID, month: month), default: []].append(entry)
        }

        var assignments: [EntityID: [YearMonth: MinorUnits]] = [:]
        for assignment in input.assignments {
            assignments[assignment.categoryID, default: [:]][assignment.month, default: 0] += assignment.amount
            touchedMonths.insert(assignment.month)
        }

        guard let firstMonth = touchedMonths.min(), let lastTouchedMonth = touchedMonths.max() else {
            return BudgetResult(
                months: [:],
                monthsInOrder: [],
                accountBalances: accountBalances,
                upcomingByAccount: upcomingByAccount
            )
        }
        let requestedHorizon = through ?? YearMonth(containing: asOf ?? Date())
        let orderedMonths = YearMonth.range(
            from: firstMonth,
            through: max(lastTouchedMonth, requestedHorizon)
        )

        let spendingCategories = input.categories.filter { $0.kind == .normal }
        let paymentCategories = input.categories.filter { $0.kind == .creditCardPayment }

        var months: [YearMonth: MonthState] = [:]
        var carryover: [EntityID: MinorUnits] = [:]
        var cumulativeInflow: MinorUnits = 0
        var cumulativeBoundaryFlow: MinorUnits = 0
        var cumulativeAssigned: MinorUnits = 0
        var cumulativeOnBudget: MinorUnits = 0
        var cashOverspendingBroughtForward: MinorUnits = 0
        var cardBalances: [EntityID: MinorUnits] = [:]
        // Money given a job in a later month is not free now: assigning next month's rent today
        // must take it off what there is to assign today, as YNAB does. Only from the current month
        // on, though. A past month shows what was left at its end, and subtracting what was
        // assigned since, without the money that has come in since, sank every earlier month
        // further below zero: August read −$13,858.92 against October's $534.60.
        // `asOf` is already a budget day, so its month is the budget's current one.
        let currentMonth = asOf.map { YearMonth(containing: $0) } ?? .current()
        let envelopeIDs = Set((spendingCategories + paymentCategories).map(\.id))
        let everythingAssigned = assignments
            .filter { envelopeIDs.contains($0.key) }
            .reduce(0) { total, category in total + category.value.values.reduce(0, +) }

        for month in orderedMonths {
            var state = MonthState(month: month)
            state.inflowTotal = inflowByMonth[month] ?? 0
            cumulativeInflow += state.inflowTotal

            for (cardID, movements) in cardMovementByMonth {
                cardBalances[cardID, default: 0] += movements[month] ?? 0
            }

            // Derived movement into each card's payment category, filled in by the first pass.
            var fundedCardSpending: [EntityID: MinorUnits] = [:]

            // Pass 1: spending categories. These never depend on payment categories, so they can be
            // settled first — and they determine how much each card's payment category receives.
            for category in spendingCategories {
                let key = CategoryMonthKey(category: category.id, month: month)
                let entries = entriesByKey[key] ?? []
                let assigned = assignments[category.id]?[month] ?? 0
                let carriedIn = carryover[category.id] ?? 0

                if entries.isEmpty, assigned == 0, carriedIn == 0 { continue }

                let activity = entries.reduce(0) { $0 + $1.amount }
                let categoryState = CategoryMonthState(assigned: assigned, activity: activity, carriedIn: carriedIn)
                state.categories[category.id] = categoryState
                state.assignedTotal += assigned
                state.activityTotal += activity

                // Walk the month's entries in order, tracking what the category can still cover.
                // Order matters: the same charges against the same funds split differently between
                // cash and credit overspending depending on when they landed.
                var runningFunds = carriedIn + assigned
                var uncoveredCardSpending: MinorUnits = 0
                for entry in entries.sorted(by: Self.chronological) {
                    if let paymentCategoryID = paymentCategoryByAccount[entry.accountID],
                       let account = accountsByID[entry.accountID],
                       account.onBudget, account.type.isCredit {
                        if entry.amount < 0 {
                            let covered = max(0, min(runningFunds, -entry.amount))
                            fundedCardSpending[paymentCategoryID, default: 0] += covered
                            uncoveredCardSpending += -entry.amount - covered
                        } else {
                            // A refund shrinks the debt, so it moves back out of the payment category.
                            fundedCardSpending[paymentCategoryID, default: 0] += -entry.amount
                        }
                    }
                    runningFunds += entry.amount
                }

                let available = categoryState.available
                let overspending = max(0, -available)
                // Whatever a card absorbed became debt; only the rest is a claim on next month.
                let creditPortion = min(overspending, uncoveredCardSpending)
                state.categories[category.id]?.creditOverspending = creditPortion
                state.creditOverspending += creditPortion
                state.cashOverspending += overspending - creditPortion
                carryover[category.id] = available >= 0 ? available : 0
            }

            // Pass 2: payment categories, now that pass 1 has decided what they received.
            for category in paymentCategories {
                let key = CategoryMonthKey(category: category.id, month: month)
                let direct = (entriesByKey[key] ?? []).reduce(0) { $0 + $1.amount }
                let activity = direct + (fundedCardSpending[category.id] ?? 0) + (cardPaymentsByKey[key] ?? 0)
                let assigned = assignments[category.id]?[month] ?? 0
                let carriedIn = carryover[category.id] ?? 0

                if activity == 0, assigned == 0, carriedIn == 0 { continue }

                let categoryState = CategoryMonthState(assigned: assigned, activity: activity, carriedIn: carriedIn)
                state.categories[category.id] = categoryState
                state.assignedTotal += assigned
                state.activityTotal += activity

                // A payment category left negative means the card's debt outgrew the money set
                // aside for it. That is debt carried on the card, not cash already spent, so it
                // resets without any claim on next month's Ready to Assign. Validating against the
                // real export settles this: treating it as a claim understated Ready to Assign by
                // more than $6,500 over seven years.
                //
                // Except as far as the card is in credit. Paying a card beyond what it owes, or a
                // credit landing on it, takes the category below zero without any debt at all: the
                // card holds that money, and the next charges will use it up. Carried forward, those
                // charges bring the category back to zero as they consume the credit. Cleared, the
                // cash that paid it would have come out of no envelope — $2.52 on the real Atlas card
                // in February 2025, and the category has held $2.52 more than the card owed since.
                let available = categoryState.available
                let credit = category.linkedAccountID.map { max(0, cardBalances[$0] ?? 0) } ?? 0
                if available >= -credit {
                    carryover[category.id] = available
                } else {
                    carryover[category.id] = -credit
                    state.unfundedCardDebt += -available - credit
                }
            }

            cumulativeAssigned += state.assignedTotal
            cumulativeOnBudget += onBudgetByMonth[month] ?? 0
            state.onBudgetFunds = cumulativeOnBudget
            state.envelopesHold = state.categories.values.reduce(0) { $0 + max(0, $1.available) }

            cumulativeBoundaryFlow += boundaryFlowByMonth[month] ?? 0

            // What came in, less what has been given a job, less cash overspent in a month already
            // gone. Spending does not appear here: it belongs to the category it came out of.
            state.assignedInFuture = month >= currentMonth ? everythingAssigned - cumulativeAssigned : 0
            let raw = cumulativeInflow + cumulativeBoundaryFlow
                - cumulativeAssigned - state.assignedInFuture - cashOverspendingBroughtForward
            state.uncappedReadyToAssign = raw
            state.readyToAssign = raw
            cashOverspendingBroughtForward += state.cashOverspending

            months[month] = state
        }

        return BudgetResult(
            months: months,
            monthsInOrder: orderedMonths,
            accountBalances: accountBalances,
            upcomingByAccount: upcomingByAccount,
            uncategorized: uncategorized.sorted(by: Self.chronological).map(\.id),
            upcomingByCategory: upcomingByCategory
        )
    }

    /// Whether this entry moves money between the budget and something outside it.
    ///
    /// Only one side is counted — the one on the budget account — because the other is in a tracked
    /// account where the budget does not reach.
    private func crossesBudgetBoundary(
        _ entry: BudgetEntry,
        accounts: [EntityID: BudgetAccount]
    ) -> Bool {
        guard let counterID = entry.transferCounterAccountID,
              let here = accounts[entry.accountID],
              let there = accounts[counterID]
        else { return false }
        return here.onBudget && !there.onBudget
    }

    /// A payment into a card from another budget account. A transfer *out* of the card is a cash
    /// advance: it raises debt without setting money aside, so it funds no payment.
    private func isPaymentToCard(_ entry: BudgetEntry, accounts: [EntityID: BudgetAccount]) -> Bool {
        guard let account = accounts[entry.accountID], account.onBudget, account.type.isCredit,
              entry.amount > 0,
              let counterAccountID = entry.transferCounterAccountID,
              let counterAccount = accounts[counterAccountID], counterAccount.onBudget
        else { return false }
        return true
    }

    /// Deterministic ordering for entries sharing a date.
    private static func chronological(_ lhs: BudgetEntry, _ rhs: BudgetEntry) -> Bool {
        lhs.date == rhs.date
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.date < rhs.date
    }
}
