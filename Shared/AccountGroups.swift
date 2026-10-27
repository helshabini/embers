import EmbersData
import SwiftData
import SwiftUI

/// The accounts as they are listed: cash, cards, tracking, closed.
///
/// Cards sit apart from cash: one is money you have, the other money you owe.
struct AccountGroups {
    let cash: [Account]
    let credit: [Account]
    let tracking: [Account]
    let closed: [Account]

    init(_ accounts: [Account]) {
        cash = accounts.filter { $0.onBudget && !$0.closed && !$0.type.isCredit }
        credit = accounts.filter { $0.onBudget && !$0.closed && $0.type.isCredit }
        tracking = accounts.filter { !$0.onBudget && !$0.closed }
        closed = accounts.filter(\.closed)
    }

    /// Renumbers every account so a move inside one group cannot collide with another's order.
    func reorder(_ group: [Account], from offsets: IndexSet, to destination: Int, in context: ModelContext) {
        var moved = group
        moved.move(fromOffsets: offsets, toOffset: destination)

        var rank = 0
        for each in [cash, credit, tracking, closed] {
            let isMovedGroup = each.first?.identifier == group.first?.identifier && each.count == group.count
            for account in (isMovedGroup ? moved : each) {
                account.order = rank
                rank += 1
            }
        }
        try? context.save()
    }
}
