import Foundation
import EmbersCore

/// A fixture mirroring a real plan's shape: a checking account, a credit card, a tracking account,
/// and all three category kinds.
private struct Fixture {
    var checking = BudgetAccount(name: "Checking", type: .checking)
    var card = BudgetAccount(name: "Card", type: .creditCard)
    var tracking = BudgetAccount(name: "Brokerage", type: .investment)
    var inflow = BudgetCategory(name: "Ready to Assign", groupName: "Inflow", kind: .inflowReadyToAssign)
    var groceries = BudgetCategory(name: "Groceries", groupName: "Immediate Obligations")
    var dining = BudgetCategory(name: "Dining Out", groupName: "Just for Fun")
    var cardPayment: BudgetCategory

    init() {
        cardPayment = BudgetCategory(
            name: "Card",
            groupName: "Credit Card Payments",
            kind: .creditCardPayment,
            linkedAccountID: card.id
        )
    }
}

private let january = YearMonth(year: 2026, month: 1)
private let february = YearMonth(year: 2026, month: 2)
private let march = YearMonth(year: 2026, month: 3)

private func day(_ month: YearMonth, _ day: Int) -> Date {
    Calendar.gregorianUTC.date(
        from: DateComponents(year: month.year, month: month.month, day: day, hour: 12)
    )!
}

/// Computes through an explicit horizon so the checks never depend on today's date.
private func compute(
    _ fixture: Fixture,
    entries: [BudgetEntry],
    assignments: [BudgetAssignment] = [],
    asOf: Date? = nil,
    through: YearMonth = march
) -> BudgetResult {
    let input = BudgetInput(
        accounts: [fixture.checking, fixture.card, fixture.tracking],
        categories: [fixture.inflow, fixture.groceries, fixture.dining, fixture.cardPayment],
        entries: entries,
        assignments: assignments
    )
    return BudgetEngine().compute(input, asOf: asOf, through: through)
}

func budgetEngineChecks(_ check: Checker) {
    check.suite("Budget engine") {
        check.test("available is carry-in plus assigned plus activity, and a surplus carries forward") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 15),
                                categoryID: fixture.groceries.id, amount: -10_000),
                ],
                assignments: [
                    BudgetAssignment(categoryID: fixture.groceries.id, month: january, amount: 30_000),
                ]
            )

            let januaryState = result.state(of: fixture.groceries.id, in: january)
            check.expect(januaryState.assigned, 30_000)
            check.expect(januaryState.activity, -10_000)
            check.expect(januaryState.carriedIn, 0)
            check.expect(januaryState.available, 20_000)
            check.expect(result.readyToAssign(in: january), 70_000)

            let februaryState = result.state(of: fixture.groceries.id, in: february)
            check.expect(februaryState.carriedIn, 20_000)
            check.expect(februaryState.available, 20_000)
            check.expect(result.readyToAssign(in: february), 70_000)
        }

        check.test("cash overspending resets the category and reduces next month's Ready to Assign") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 20),
                                categoryID: fixture.groceries.id, amount: -15_000),
                ],
                assignments: [
                    BudgetAssignment(categoryID: fixture.groceries.id, month: january, amount: 10_000),
                ]
            )

            check.expect(result.state(of: fixture.groceries.id, in: january).available, -5_000)
            // January is what came in less what was assigned. The overspend is the category's
            // problem in January and the budget's in February — spending is not assigning.
            check.expect(result.readyToAssign(in: january), 90_000)
            check.expect(result.state(of: fixture.groceries.id, in: february).carriedIn, 0)
            check.expect(result.readyToAssign(in: february), 85_000)
            // Deducted once, not again in the month after.
            check.expect(result.readyToAssign(in: march), 85_000)
        }

        check.test("spending on a credit card funds that card's payment category") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                    BudgetEntry(accountID: fixture.card.id, date: day(january, 10),
                                categoryID: fixture.groceries.id, amount: -8_000),
                ],
                assignments: [
                    BudgetAssignment(categoryID: fixture.groceries.id, month: january, amount: 20_000),
                ]
            )

            check.expect(result.state(of: fixture.groceries.id, in: january).activity, -8_000)
            check.expect(result.state(of: fixture.groceries.id, in: january).available, 12_000)
            check.expect(result.state(of: fixture.cardPayment.id, in: january).activity, 8_000)
            check.expect(result.state(of: fixture.cardPayment.id, in: january).available, 8_000)
            check.expect(result.accountBalances[fixture.card.id], -8_000)
        }

        check.test("paying the card empties its payment category") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                    BudgetEntry(accountID: fixture.card.id, date: day(january, 10),
                                categoryID: fixture.groceries.id, amount: -8_000),
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 28),
                                amount: -8_000, transferCounterAccountID: fixture.card.id),
                    BudgetEntry(accountID: fixture.card.id, date: day(january, 28),
                                amount: 8_000, transferCounterAccountID: fixture.checking.id),
                ],
                assignments: [
                    BudgetAssignment(categoryID: fixture.groceries.id, month: january, amount: 8_000),
                ]
            )

            check.expect(result.state(of: fixture.cardPayment.id, in: january).activity, 0)
            check.expect(result.accountBalances[fixture.card.id], 0)
            check.expect(result.accountBalances[fixture.checking.id], 92_000)
        }

        // Atlas MasterCard, Aug 2019 in the real export: two categorised outflows, one card payment
        // in, and pre-existing debt on the inflow category. YNAB exported -584.59 for both fields.
        check.test("reproduces the export's Aug 2019 payment-category activity of -584.59") {
            let fixture = Fixture()
            let august = YearMonth(year: 2019, month: 8)
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.card.id, date: day(august, 28),
                                categoryID: fixture.groceries.id, amount: -97),
                    BudgetEntry(accountID: fixture.card.id, date: day(august, 19),
                                categoryID: fixture.dining.id, amount: -20_340),
                    BudgetEntry(accountID: fixture.card.id, date: day(august, 22),
                                amount: 78_896, transferCounterAccountID: fixture.checking.id),
                    BudgetEntry(accountID: fixture.checking.id, date: day(august, 22),
                                amount: -78_896, transferCounterAccountID: fixture.card.id),
                    BudgetEntry(accountID: fixture.card.id, date: day(august, 1),
                                categoryID: fixture.inflow.id, amount: -144_005),
                ],
                assignments: [
                    BudgetAssignment(categoryID: fixture.groceries.id, month: august, amount: 97),
                    BudgetAssignment(categoryID: fixture.dining.id, month: august, amount: 20_340),
                ]
            )

            let payment = result.state(of: fixture.cardPayment.id, in: august)
            check.expect(payment.activity, -58_459)
            check.expect(payment.available, -58_459)
            // The negative does not carry into the next month.
            check.expect(result.state(of: fixture.cardPayment.id, in: august.next).carriedIn, 0)
        }

        // Charging more than a category holds cannot set aside money that isn't there. This is the
        // Meridian / Dining Out case from the real export: an 88.80 charge moved only 35.96.
        check.test("card spending beyond a category's funds is only partly funded") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                    BudgetEntry(accountID: fixture.card.id, date: day(january, 20),
                                categoryID: fixture.dining.id, amount: -8_880),
                ],
                assignments: [
                    BudgetAssignment(categoryID: fixture.dining.id, month: january, amount: 3_596),
                ]
            )

            check.expect(result.state(of: fixture.dining.id, in: january).available, -5_284)
            check.expect(result.state(of: fixture.cardPayment.id, in: january).activity, 3_596)
            check.expect(result.months[january]?.creditOverspending, 5_284)
            check.expect(result.months[january]?.cashOverspending, 0)
            // Credit overspending is debt, so next month's Ready to Assign is untouched.
            check.expect(result.readyToAssign(in: february), result.readyToAssign(in: january))
        }

        check.test("the same overspend paid from checking reduces next month instead") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 20),
                                categoryID: fixture.dining.id, amount: -8_880),
                ],
                assignments: [
                    BudgetAssignment(categoryID: fixture.dining.id, month: january, amount: 3_596),
                ]
            )

            check.expect(result.months[january]?.cashOverspending, 5_284)
            check.expect(result.months[january]?.creditOverspending, 0)
            check.expect(
                result.readyToAssign(in: february),
                result.readyToAssign(in: january) - 5_284,
                "the overspend comes off the month after the one it happened in"
            )
            check.expect(result.readyToAssign(in: january), 96_404)
            check.expect(result.readyToAssign(in: february), 91_120)
        }

        // Paying a card more than was set aside leaves its payment category negative. That shortfall
        // is debt still carried on the card, not cash already spent, so it must not be deducted from
        // next month's Ready to Assign. Doing so understated the real export by over $6,500.
        check.test("an overpaid card carries its credit, without touching Ready to Assign") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                    BudgetEntry(accountID: fixture.card.id, date: day(january, 10),
                                categoryID: fixture.groceries.id, amount: -10_000),
                    // Overpay the card by 20,000 beyond what was set aside.
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 28),
                                amount: -30_000, transferCounterAccountID: fixture.card.id),
                    BudgetEntry(accountID: fixture.card.id, date: day(january, 28),
                                amount: 30_000, transferCounterAccountID: fixture.checking.id),
                ],
                assignments: [
                    BudgetAssignment(categoryID: fixture.groceries.id, month: january, amount: 10_000),
                ]
            )

            check.expect(result.state(of: fixture.cardPayment.id, in: january).available, -20_000)
            check.expect(result.months[january]?.unfundedCardDebt, 0, "a card in credit owes nothing")
            check.expect(result.months[january]?.cashOverspending, 0)
            // The card holds the 20,000; carried, the next charges bring the category back to zero
            // as they use it up. Cleared, the cash that paid it would have come out of no envelope.
            check.expect(result.state(of: fixture.cardPayment.id, in: february).carriedIn, -20_000)
            check.expect(result.readyToAssign(in: february), result.readyToAssign(in: january))
            check.expect(result.readyToAssign(in: january), 90_000)
        }

        check.test("debt nobody set money aside for still clears without a claim") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                    // Nothing assigned: the charge is credit overspending, and the card owes it.
                    BudgetEntry(accountID: fixture.card.id, date: day(january, 10),
                                categoryID: fixture.groceries.id, amount: -10_000),
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 28),
                                amount: -10_000, transferCounterAccountID: fixture.card.id),
                    BudgetEntry(accountID: fixture.card.id, date: day(january, 28),
                                amount: 10_000, transferCounterAccountID: fixture.checking.id),
                ]
            )

            check.expect(result.state(of: fixture.cardPayment.id, in: january).available, -10_000)
            check.expect(result.months[january]?.unfundedCardDebt, 10_000)
            check.expect(result.state(of: fixture.cardPayment.id, in: february).carriedIn, 0)
        }

        check.test("a credit on a card counted as income leaves its payment category") {
            // The real Meridian card: paid off, then a 52.84 credit filed under Ready to Assign, then an
            // 88.80 charge of which only 35.96 was left to pay.
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                    BudgetEntry(accountID: fixture.card.id, date: day(january, 16),
                                categoryID: fixture.inflow.id, amount: 5_284),
                    BudgetEntry(accountID: fixture.card.id, date: day(february, 23),
                                categoryID: fixture.dining.id, amount: -8_880),
                    BudgetEntry(accountID: fixture.checking.id, date: day(march, 4),
                                amount: -3_596, transferCounterAccountID: fixture.card.id),
                    BudgetEntry(accountID: fixture.card.id, date: day(march, 4),
                                amount: 3_596, transferCounterAccountID: fixture.checking.id),
                ],
                assignments: [
                    BudgetAssignment(categoryID: fixture.dining.id, month: february, amount: 8_880),
                ]
            )

            check.expect(result.state(of: fixture.cardPayment.id, in: january).available, -5_284,
                         "the credit is money the card holds, not cash set aside")
            check.expect(result.state(of: fixture.cardPayment.id, in: february).available, 3_596,
                         "set aside: only what the charge left owing")
            check.expect(result.state(of: fixture.cardPayment.id, in: march).available, 0,
                         "paid off, nothing left set aside for nothing")
            check.expect(result.accountBalances[fixture.card.id], 0)

            // Every dollar in cash is either assigned or still to assign: the credit counted once.
            let state = try check.unwrap(result.months[march])
            let cash = result.accountBalances[fixture.checking.id] ?? 0
            let assignedAndHeld = state.categories.values.reduce(0) { $0 + $1.available }
            check.expect(state.readyToAssign + assignedAndHeld, cash)
        }

        check.test("a cash advance out of the card does not fund its payment category") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.card.id, date: day(january, 5),
                                amount: -50_000, transferCounterAccountID: fixture.checking.id),
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 5),
                                amount: 50_000, transferCounterAccountID: fixture.card.id),
                ]
            )
            check.expect(result.state(of: fixture.cardPayment.id, in: january).activity, 0)
        }

        check.test("moving money between budget accounts leaves Ready to Assign untouched") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 9),
                                amount: -25_000, transferCounterAccountID: fixture.card.id),
                    BudgetEntry(accountID: fixture.card.id, date: day(january, 9),
                                amount: 25_000, transferCounterAccountID: fixture.checking.id),
                ]
            )
            check.expect(result.readyToAssign(in: january), 100_000)
            check.expect(result.netWorth, 100_000)
        }

        // Money sent to a tracking account with no category on it has left the budget without being
        // budgeted for, so it is no longer assignable. A categorised one is spending, and belongs to
        // its category — that is the mortgage case, checked separately.
        check.test("uncategorised money leaving the budget reduces Ready to Assign") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 9),
                                amount: -25_000, transferCounterAccountID: fixture.tracking.id),
                    BudgetEntry(accountID: fixture.tracking.id, date: day(january, 9),
                                amount: 25_000, transferCounterAccountID: fixture.checking.id),
                ]
            )
            check.expect(result.readyToAssign(in: january), 75_000)
            check.expect(result.netWorth, 100_000, "net worth is unchanged; only the budget shrank")
        }

        // The app requires a category on any transfer across this edge, in either direction, so
        // this is about data already written before it did — a transfer out of a certificate of
        // deposit that nothing in the budget accounted for.
        check.test("uncategorised money arriving from a tracked account becomes assignable") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                    BudgetEntry(accountID: fixture.tracking.id, date: day(january, 9),
                                amount: -24_000, transferCounterAccountID: fixture.checking.id),
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 9),
                                amount: 24_000, transferCounterAccountID: fixture.tracking.id),
                ]
            )
            check.expect(
                result.readyToAssign(in: january), 124_000,
                "money that joins the budget with no envelope is money to assign"
            )
            check.expect(result.netWorth, 100_000, "and net worth has not moved")
        }

        check.test("a categorised transfer out of the budget is spending, not a deduction") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 9),
                                categoryID: fixture.groceries.id, amount: -25_000,
                                transferCounterAccountID: fixture.tracking.id),
                    BudgetEntry(accountID: fixture.tracking.id, date: day(january, 9),
                                amount: 25_000, transferCounterAccountID: fixture.checking.id),
                ],
                assignments: [
                    BudgetAssignment(categoryID: fixture.groceries.id, month: january, amount: 25_000),
                ]
            )
            check.expect(
                result.readyToAssign(in: january), 75_000,
                "assigning the money is what moved it, not spending it"
            )
            check.expect(result.state(of: fixture.groceries.id, in: january).available, 0)
        }

        // What the person picks is what happens. Ready to Assign on a boundary transfer says "this
        // money has no job yet" on the way in, and "take it off the top" on the way out.
        check.test("picking Ready to Assign gives the same answer as leaving it uncategorised") {
            func arrival(categorised: Bool) -> BudgetResult {
                let fixture = Fixture()
                return compute(
                    fixture,
                    entries: [
                        BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                    categoryID: fixture.inflow.id, amount: 100_000),
                        BudgetEntry(accountID: fixture.tracking.id, date: day(january, 9),
                                    amount: -24_000,
                                    transferCounterAccountID: fixture.checking.id),
                        BudgetEntry(accountID: fixture.checking.id, date: day(january, 9),
                                    categoryID: categorised ? fixture.inflow.id : nil,
                                    amount: 24_000,
                                    transferCounterAccountID: fixture.tracking.id),
                    ]
                )
            }
            check.expect(arrival(categorised: false).readyToAssign(in: january), 124_000)
            check.expect(
                arrival(categorised: true).readyToAssign(in: january), 124_000,
                "naming it must not count it twice"
            )
        }

        check.test("Ready to Assign on the way out takes it off the top") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 9),
                                categoryID: fixture.inflow.id, amount: -25_000,
                                transferCounterAccountID: fixture.tracking.id),
                    BudgetEntry(accountID: fixture.tracking.id, date: day(january, 9),
                                amount: 25_000, transferCounterAccountID: fixture.checking.id),
                ]
            )
            check.expect(
                result.readyToAssign(in: january), 75_000,
                "money moved out of the budget without coming from any envelope"
            )
            check.expect(result.netWorth, 100_000, "and it is still the same money overall")
        }

        // Why the export omits a 09/30/2026 mortgage payment from Sep 2026 activity — and why a
        // payment scheduled for next May must not be subtracted from today's balance.
        check.test("upcoming transactions stay out of both the balance and the budget") {
            let fixture = Fixture()
            let entries = [
                BudgetEntry(accountID: fixture.checking.id, date: day(january, 10),
                            categoryID: fixture.groceries.id, amount: -5_000),
                BudgetEntry(accountID: fixture.checking.id, date: day(january, 20),
                            categoryID: fixture.groceries.id, amount: -30_000),
            ]

            let withCutoff = compute(fixture, entries: entries, asOf: day(january, 15))
            check.expect(withCutoff.state(of: fixture.groceries.id, in: january).activity, -5_000)
            check.expect(withCutoff.accountBalances[fixture.checking.id], -5_000, "working balance")
            check.expect(withCutoff.upcoming(for: fixture.checking.id), -30_000, "upcoming")
            check.expect(withCutoff.projectedBalance(of: fixture.checking.id), -35_000)
            check.expect(withCutoff.netWorth, -5_000, "net worth counts today, not the future")

            let withoutCutoff = compute(fixture, entries: entries)
            check.expect(withoutCutoff.state(of: fixture.groceries.id, in: january).activity, -35_000)
            check.expect(withoutCutoff.accountBalances[fixture.checking.id], -35_000)
            check.expect(withoutCutoff.upcoming(for: fixture.checking.id), 0)
        }

        check.test("money assigned to a later month is off Ready to Assign now") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                ],
                assignments: [
                    BudgetAssignment(categoryID: fixture.groceries.id, month: january, amount: 20_000),
                    BudgetAssignment(categoryID: fixture.groceries.id, month: march, amount: 30_000),
                ],
                asOf: day(january, 15)
            )

            check.expect(result.readyToAssign(in: january), 50_000, "March's rent is not free in January")
            check.expect(result.months[january]?.assignedInFuture, 30_000)
            check.expect(result.readyToAssign(in: march), 50_000, "and the figure does not move when March comes")
            check.expect(result.months[march]?.assignedInFuture, 0)
        }

        check.test("a past month shows what was left at its end") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                    BudgetEntry(accountID: fixture.checking.id, date: day(march, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                ],
                assignments: [
                    BudgetAssignment(categoryID: fixture.groceries.id, month: january, amount: 20_000),
                    BudgetAssignment(categoryID: fixture.groceries.id, month: march, amount: 150_000),
                ],
                asOf: day(march, 15)
            )

            // March assigned more than January ever had. Taken off January without March's income,
            // January would read −70,000; going further back only sank it deeper.
            check.expect(result.readyToAssign(in: january), 80_000)
            check.expect(result.months[january]?.assignedInFuture, 0)
            check.expect(result.readyToAssign(in: march), 30_000)
        }

        check.test("net worth sums every account, on budget or not") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 500_000),
                    BudgetEntry(accountID: fixture.card.id, date: day(january, 3),
                                categoryID: fixture.groceries.id, amount: -30_000),
                    BudgetEntry(accountID: fixture.tracking.id, date: day(january, 4),
                                categoryID: fixture.inflow.id, amount: 120_000),
                ]
            )
            check.expect(result.netWorth, 590_000)
        }

        check.test("an empty plan produces no months") {
            let result = BudgetEngine().compute(BudgetInput())
            check.expectTrue(result.monthsInOrder.isEmpty)
            check.expect(result.netWorth, 0)
        }
    }
}

func categoryStatusChecks(_ check: Checker) {
    check.suite("A category's colour") {
        check.test("says what to do, one case each") {
            func status(_ available: MinorUnits, credit: MinorUnits = 0, upcoming: MinorUnits = 0) -> CategoryStatus {
                var state = CategoryMonthState(assigned: available)
                state.creditOverspending = credit
                return CategoryStatus(state, upcoming: upcoming)
            }
            check.expect(status(0), .empty)
            check.expect(status(5_000), .funded)
            check.expect(status(5_000, upcoming: -5_000), .funded, "exactly enough for what is coming")
            check.expect(status(5_000, upcoming: -8_000), .underfunded(needed: 3_000))
            check.expect(status(0, upcoming: -8_000), .underfunded(needed: 8_000))
            check.expect(status(0, upcoming: 2_000), .empty, "a refund to come asks for nothing")
            check.expect(status(-3_000, credit: 3_000), .creditOverspent)
            check.expect(status(-3_000, credit: 1_000), .overspent, "any cash in the overspend makes it red")
        }

        check.test("knows what is still to come in each category") {
            let fixture = Fixture()
            let result = compute(
                fixture,
                entries: [
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 1),
                                categoryID: fixture.inflow.id, amount: 100_000),
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 5),
                                categoryID: fixture.groceries.id, amount: -2_000),
                    BudgetEntry(accountID: fixture.checking.id, date: day(january, 25),
                                categoryID: fixture.groceries.id, amount: -6_000),
                    BudgetEntry(accountID: fixture.card.id, date: day(january, 6),
                                categoryID: fixture.dining.id, amount: -4_000),
                ],
                assignments: [
                    BudgetAssignment(categoryID: fixture.groceries.id, month: january, amount: 5_000),
                ],
                asOf: day(january, 10),
                through: january
            )

            check.expect(result.upcoming(of: fixture.groceries.id, in: january), -6_000)
            let groceries = result.state(of: fixture.groceries.id, in: january)
            check.expect(groceries.available, 3_000, "what is coming is not spent yet")
            check.expect(
                CategoryStatus(groceries, upcoming: result.upcoming(of: fixture.groceries.id, in: january)),
                .underfunded(needed: 3_000)
            )
            let dining = result.state(of: fixture.dining.id, in: january)
            check.expect(dining.creditOverspending, 4_000)
            check.expect(CategoryStatus(dining, upcoming: 0), .creditOverspent)
        }
    }
}
