import Foundation

/// How a category stands this month, as YNAB colours it.
///
/// One question per colour, so each tells the person what to do: red, cover what was spent; orange,
/// assign what is still to come (or, for card spending, know that it became debt); green, nothing;
/// grey, nothing there and nothing needed.
public enum CategoryStatus: Hashable, Sendable {
    /// Nothing available and nothing coming.
    case empty
    /// Holds money, and enough of it for everything still to come this month.
    case funded
    /// Holds less than what is still to come this month. `needed` is the difference to assign.
    case underfunded(needed: MinorUnits)
    /// Overspent, all of it charged to a card: it became debt rather than coming out of next month.
    case creditOverspent
    /// Overspent with cash. Comes out of next month's Ready to Assign unless covered now.
    case overspent

    /// - Parameter upcoming: What is entered for this category later in the month and has not
    ///   happened yet; outflows negative. Only outflows ask for money: a refund still to arrive is
    ///   not something to assign against.
    public init(_ state: CategoryMonthState, upcoming: MinorUnits) {
        let available = state.available
        if available < 0 {
            self = state.creditOverspending >= -available ? .creditOverspent : .overspent
            return
        }
        let comingOut = max(0, -upcoming)
        if comingOut > available {
            self = .underfunded(needed: comingOut - available)
        } else {
            self = available == 0 ? .empty : .funded
        }
    }
}
