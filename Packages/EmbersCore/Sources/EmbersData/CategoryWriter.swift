import Foundation
import EmbersCore
import SwiftData

/// Editing the plan: adding, renaming, hiding and — rarely — deleting.
///
/// Two rules shape all of it. A category that money has passed through is history, and history is not
/// deleted: it is hidden, which keeps every past month's figures intact while taking it off the
/// screen. And the credit card group is not the user's to edit — it follows the accounts.
@MainActor
public enum CategoryWriter {
    public enum Refusal: LocalizedError, Equatable {
        case nameIsEmpty
        case nameAlreadyUsed(String)
        case managedByTheApp
        case starterGroup
        case hasHistory(transactions: Int, assignments: Int)

        public var errorDescription: String? {
            switch self {
            case .nameIsEmpty:
                String(localized: "Give it a name.", bundle: .module)
            case let .nameAlreadyUsed(name):
                String(localized: "There is already something called “\(name)” here.", bundle: .module)
            case .managedByTheApp:
                String(localized: "The app keeps this one in step with your accounts.", bundle: .module)
            case .starterGroup:
                String(
                    localized: "This group comes with the app and keeps its name. Hide it and add your own instead.",
                    bundle: .module
                )
            case let .hasHistory(transactions, assignments):
                historyReason(transactions: transactions, assignments: assignments)
            }
        }

        private func historyReason(transactions: Int, assignments: Int) -> String {
            var parts: [String] = []
            if transactions > 0 {
                parts.append(Counted.transactions(transactions))
            }
            if assignments > 0 {
                parts.append(String(localized: "money assigned in \(assignments) months", bundle: .module, locale: .display))
            }
            return String(
                localized: "This has \(Counted.list(parts)). Hide it instead — the figures stay.",
                bundle: .module
            )
        }
    }

    // MARK: - The names the app owns

    public static let creditCardGroupName = "Credit Card Payments"
    public static let hiddenGroupName = "Hidden Categories"
    public static let inflowGroupName = "Inflow"

    /// Groups the user may not rename or remove, because the app puts things in them.
    public static func isManaged(_ group: CategoryGroup) -> Bool {
        group.isSystemManaged
            || [creditCardGroupName, hiddenGroupName, inflowGroupName]
                .contains { $0.caseInsensitiveCompare(group.name) == .orderedSame }
    }

    /// A card's payment category is named after its card and emptied when the card closes, so it is
    /// not the user's to rename or delete either.
    public static func isManaged(_ category: BudgetCategoryModel) -> Bool {
        category.kind != .normal
    }

    // MARK: - The groups a new plan starts with

    /// One of the groups a new plan is seeded with. Its purpose is only a description: nothing
    /// enforces what goes in it.
    ///
    /// `name` and `categories` are the English names the plan stores; what the reader sees is
    /// `ProvidedName`'s translation of them. `purpose` is only ever shown, so it is translated here.
    public struct StarterGroup: Sendable {
        public let name: String
        public let purpose: String
        public let categories: [String]
    }

    /// YNAB's own starting groups, which an imported plan usually already has under these names.
    ///
    /// Worked out on each use rather than once, so the purposes are in the language of the moment.
    public static var starterGroups: [StarterGroup] { [
        StarterGroup(
            name: "Immediate Obligations",
            purpose: String(
                localized: "What you pay every month, in much the same amount: rent, bills, groceries, getting around. Fund these first.",
                bundle: .module
            ),
            categories: [
                "Rent", "Electricity", "Water", "Internet", "Phone", "Groceries", "Transportation",
                "Interest & Fees",
            ]
        ),
        StarterGroup(
            name: "True Expenses",
            purpose: String(
                localized: "Real costs that don't arrive monthly: school fees, car repairs, a new laptop. Set a little aside each month so they are no surprise when they come.",
                bundle: .module
            ),
            categories: [
                "Auto Maintenance", "Home Maintenance", "Medical", "Clothing", "Gifts", "Schooling",
                "Subscriptions", "Stuff I Forgot to Budget For",
            ]
        ),
        StarterGroup(
            name: "Debt Payments",
            purpose: String(
                localized: "Money owed on a schedule outside your credit cards, such as a mortgage or a loan.",
                bundle: .module
            ),
            categories: ["Mortgage", "Auto Loan", "Personal Loan"]
        ),
        StarterGroup(
            name: "Quality of Life Goals",
            purpose: String(
                localized: "Things that make life better but could wait: a holiday, a renovation, the gym. Fund them once the essentials are covered.",
                bundle: .module
            ),
            categories: ["Vacation", "Fitness", "Home Improvement", "Education"]
        ),
        StarterGroup(
            name: "Rainy Day Funds",
            purpose: String(
                localized: "Money kept for later rather than spent: an emergency cushion, savings, investments.",
                bundle: .module
            ),
            categories: ["Emergency Fund", "Savings", "Investments"]
        ),
        StarterGroup(
            name: "Just for Fun",
            purpose: String(
                localized: "Entirely optional spending, just for enjoyment: hobbies, games, eating out, money to spend on a whim.",
                bundle: .module
            ),
            categories: ["Dining Out", "Entertainment", "Hobbies", "Fun Money"]
        ),
    ] }

    /// The starter group this is, matched by name — so an imported plan's own "True Expenses" is
    /// the same group as a seeded one, and gets the same description.
    public static func starter(_ group: CategoryGroup) -> StarterGroup? {
        starterGroups.first { $0.name.caseInsensitiveCompare(group.name) == .orderedSame }
    }

    /// Gives a new plan the starter groups and categories.
    ///
    /// Only a plan with no accounts and no group of the user's own is new. The managed groups do
    /// not count: the credit card group is made at launch whether or not there is a card, so
    /// waiting for a plan with no groups at all would never seed anything.
    ///
    /// - Returns: whether anything was added.
    @discardableResult
    public static func seedStarterPlan(in context: ModelContext) throws -> Bool {
        guard try context.fetchCount(FetchDescriptor<Account>()) == 0 else { return false }
        let groups = try context.fetch(FetchDescriptor<CategoryGroup>())
        guard groups.allSatisfy(isManaged) else { return false }

        let first = (groups.map(\.order).max() ?? -1) + 1
        for (index, starter) in starterGroups.enumerated() {
            let group = CategoryGroup(name: starter.name, order: first + index)
            context.insert(group)
            for (order, name) in starter.categories.enumerated() {
                context.insert(BudgetCategoryModel(name: name, group: group, order: order))
            }
        }
        try context.save()
        return true
    }

    // MARK: - Ordering

    /// Puts the groups the user can move in the order given.
    ///
    /// The managed groups keep their places: the credit card group leads the plan, and the order
    /// values the movable groups already held are handed back out among them in the new order.
    public static func reorder(_ ordered: [CategoryGroup], in context: ModelContext) throws {
        let movable = ordered.filter { !isManaged($0) }
        let slots = movable.map(\.order).sorted()
        for (group, order) in zip(movable, slots) {
            group.order = order
        }
        try context.save()
    }

    /// Moves a category to a place in a group, which may be the one it is already in.
    ///
    /// - Parameter index: its place among the group's other categories as the plan editor lists
    ///   them, hidden ones last.
    public static func move(
        _ category: BudgetCategoryModel,
        to group: CategoryGroup,
        at index: Int,
        in context: ModelContext
    ) throws {
        guard !isManaged(category), !isManaged(group) else { throw Refusal.managedByTheApp }
        let source = category.group
        if source?.identifier != group.identifier {
            if (group.categories ?? []).contains(where: {
                $0.name.caseInsensitiveCompare(category.name) == .orderedSame
            }) { throw Refusal.nameAlreadyUsed(category.name) }
            // Everything in a hidden group is hidden, or it would float loose in the plan.
            if group.hidden { category.hidden = true }
        }

        var siblings = editorOrder(group).filter { $0.identifier != category.identifier }
        siblings.insert(category, at: min(max(index, 0), siblings.count))
        category.group = group
        for (order, sibling) in siblings.enumerated() {
            sibling.order = order
        }
        if let source, source.identifier != group.identifier {
            for (order, sibling) in editorOrder(source)
                .filter({ $0.identifier != category.identifier }).enumerated() {
                sibling.order = order
            }
        }
        try context.save()
    }

    /// A group's categories as the plan editor lists them: in order, with the hidden ones last.
    public static func editorOrder(_ group: CategoryGroup) -> [BudgetCategoryModel] {
        (group.categories ?? [])
            .filter { $0.kind != .inflowReadyToAssign }
            .sorted { ($0.hidden ? 1 : 0, $0.order) < ($1.hidden ? 1 : 0, $1.order) }
    }

    // MARK: - Groups

    @discardableResult
    public static func addGroup(named name: String, in context: ModelContext) throws -> CategoryGroup {
        let trimmed = try cleanName(name)
        let groups = try context.fetch(FetchDescriptor<CategoryGroup>())
        guard !groups.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { throw Refusal.nameAlreadyUsed(trimmed) }

        let group = CategoryGroup(name: trimmed, order: (groups.map(\.order).max() ?? -1) + 1)
        context.insert(group)
        try context.save()
        return group
    }

    public static func rename(_ group: CategoryGroup, to name: String, in context: ModelContext) throws {
        guard !isManaged(group) else { throw Refusal.managedByTheApp }
        // Its description is written for its name; renamed, the description would describe
        // something else.
        guard starter(group) == nil else { throw Refusal.starterGroup }
        let trimmed = try cleanName(name)
        guard trimmed.caseInsensitiveCompare(group.name) != .orderedSame else { return }
        let groups = try context.fetch(FetchDescriptor<CategoryGroup>())
        guard !groups.contains(where: {
            $0.identifier != group.identifier
                && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { throw Refusal.nameAlreadyUsed(trimmed) }

        group.name = trimmed
        try context.save()
    }

    /// Whether a group can go for good: not one the app manages, and nothing in it with a past.
    public static func deletionRefusal(
        for group: CategoryGroup,
        in context: ModelContext
    ) throws -> Refusal? {
        if isManaged(group) { return .managedByTheApp }
        // A starter group the person has no use for is hidden, which keeps it out of the way
        // without the plan losing the shape the descriptions are written for.
        if starter(group) != nil { return .starterGroup }
        var transactions = 0
        var assignments = 0
        for category in group.categories ?? [] {
            let history = try history(of: category, in: context)
            transactions += history.transactions
            assignments += history.assignments
        }
        guard transactions == 0, assignments == 0 else {
            return .hasHistory(transactions: transactions, assignments: assignments)
        }
        return nil
    }

    public static func delete(_ group: CategoryGroup, in context: ModelContext) throws {
        if let refusal = try deletionRefusal(for: group, in: context) { throw refusal }
        context.delete(group)
        try context.save()
    }

    public static func setHidden(_ hidden: Bool, on group: CategoryGroup, in context: ModelContext) throws {
        guard !isManaged(group) else { throw Refusal.managedByTheApp }
        group.hidden = hidden
        // A hidden group's categories go with it, or they would float loose in the plan.
        for category in group.categories ?? [] where category.kind == .normal {
            category.hidden = hidden
        }
        try context.save()
    }

    // MARK: - The credit card group, which follows the accounts

    /// Brings the credit card group in step with the accounts.
    ///
    /// The group is not a list anyone maintains: it is one category per open credit account, named
    /// after its card. A card that closes keeps its category — past months spent against that card
    /// and the figures must stand — but it goes to the hidden group, which is where the YNAB export
    /// parks closed cards too, and where the importer reads them back from.
    ///
    /// - Returns: what changed, for anything that wants to say so.
    @discardableResult
    public static func syncCreditCardCategories(
        in context: ModelContext
    ) throws -> (added: Int, hidden: Int, restored: Int, renamed: Int) {
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let categories = try context.fetch(FetchDescriptor<BudgetCategoryModel>())
        var payment = categories.filter { $0.kind == .creditCardPayment }

        // The group exists whether or not there is a card in it: it leads the plan, and something
        // that cannot be renamed or deleted should not be able to quietly not be there either. The
        // plan does not draw an empty group, so nobody sees it until a card does.
        let cardGroup = try group(named: creditCardGroupName, in: context)

        var added = 0, hidden = 0, restored = 0, renamed = 0

        for account in accounts where account.type.isCredit && !account.closed {
            // The lowest identifier, as `SyncMerge` keeps: while a card has two categories from two
            // devices, restoring or renaming the other would bring back the one being folded away.
            let existing = payment
                .filter { $0.linkedAccount?.identifier == account.identifier }
                .min { $0.identifier.uuidString < $1.identifier.uuidString }
            guard let existing else {
                let created = BudgetCategoryModel(
                    name: account.name,
                    group: cardGroup,
                    order: (cardGroup.categories?.map(\.order).max() ?? -1) + 1,
                    kind: .creditCardPayment,
                    linkedAccount: account
                )
                context.insert(created)
                payment.append(created)
                added += 1
                continue
            }
            // A card that reopened, or that was hidden by hand, belongs back on the plan.
            if existing.hidden || existing.group?.name != creditCardGroupName {
                existing.hidden = false
                existing.group = cardGroup
                restored += 1
            }
            if existing.name != account.name {
                existing.name = account.name
                renamed += 1
            }
        }

        for category in payment {
            let account = category.linkedAccount
            // A category whose card has closed, or whose card is gone altogether.
            guard account == nil || account?.closed == true || account?.type.isCredit == false
            else { continue }
            guard !category.hidden || category.group?.name != hiddenGroupName else { continue }
            category.hidden = true
            category.group = try group(named: hiddenGroupName, in: context)
            hidden += 1
        }

        if context.hasChanges { try context.save() }
        return (added, hidden, restored, renamed)
    }

    /// Finds a group the app owns, making it if the plan has none yet.
    private static func group(named name: String, in context: ModelContext) throws -> CategoryGroup {
        let groups = try context.fetch(FetchDescriptor<CategoryGroup>())
        if let existing = groups.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            existing.isSystemManaged = true
            return existing
        }
        // The credit card group leads the plan; hidden things go to the end of it.
        let order = name == creditCardGroupName
            ? (groups.map(\.order).min() ?? 0) - 1
            : (groups.map(\.order).max() ?? -1) + 1
        let created = CategoryGroup(name: name, order: order, isSystemManaged: true)
        context.insert(created)
        return created
    }

    // MARK: - Categories

    @discardableResult
    public static func add(
        _ name: String,
        to group: CategoryGroup,
        in context: ModelContext
    ) throws -> BudgetCategoryModel {
        guard !isManaged(group) else { throw Refusal.managedByTheApp }
        let trimmed = try cleanName(name)
        let siblings = group.categories ?? []
        guard !siblings.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { throw Refusal.nameAlreadyUsed(trimmed) }

        let category = BudgetCategoryModel(
            name: trimmed, group: group, order: (siblings.map(\.order).max() ?? -1) + 1
        )
        context.insert(category)
        try context.save()
        return category
    }

    public static func rename(
        _ category: BudgetCategoryModel,
        to name: String,
        in context: ModelContext
    ) throws {
        guard !isManaged(category) else { throw Refusal.managedByTheApp }
        let trimmed = try cleanName(name)
        guard trimmed.caseInsensitiveCompare(category.name) != .orderedSame else { return }
        let siblings = category.group?.categories ?? []
        guard !siblings.contains(where: {
            $0.identifier != category.identifier
                && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { throw Refusal.nameAlreadyUsed(trimmed) }

        category.name = trimmed
        try context.save()
    }

    /// Why this category cannot be deleted, or `nil` if it can.
    public static func deletionRefusal(
        for category: BudgetCategoryModel,
        in context: ModelContext
    ) throws -> Refusal? {
        if isManaged(category) { return .managedByTheApp }
        let past = try history(of: category, in: context)
        guard past.transactions == 0, past.assignments == 0 else {
            return .hasHistory(transactions: past.transactions, assignments: past.assignments)
        }
        return nil
    }

    public static func delete(_ category: BudgetCategoryModel, in context: ModelContext) throws {
        if let refusal = try deletionRefusal(for: category, in: context) { throw refusal }
        context.delete(category)
        try context.save()
    }

    /// Takes a category off the plan without touching a figure.
    public static func setHidden(
        _ hidden: Bool,
        on category: BudgetCategoryModel,
        in context: ModelContext
    ) throws {
        guard category.kind == .normal else { throw Refusal.managedByTheApp }
        category.hidden = hidden
        try context.save()
    }

    /// What a category has been part of: the reason it can only be hidden.
    public static func history(
        of category: BudgetCategoryModel,
        in context: ModelContext
    ) throws -> (transactions: Int, assignments: Int) {
        let id = category.identifier
        let transactions = try context.fetchCount(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.category?.identifier == id }
            )
        )
        // Months whose changes leave something assigned. A month funded and then emptied again holds
        // rows that add up to nothing, and counts for nothing.
        let rows = try context.fetch(
            FetchDescriptor<CategoryAssignment>(
                predicate: #Predicate { $0.category?.identifier == id }
            )
        )
        let byMonth = Dictionary(grouping: rows, by: \.monthOrdinal)
        let assignments = byMonth.values.filter { $0.reduce(0) { $0 + $1.amountMinor } != 0 }.count
        return (transactions, assignments)
    }

    private static func cleanName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Refusal.nameIsEmpty }
        return trimmed
    }
}
