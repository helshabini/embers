import Foundation

public typealias EntityID = UUID

public enum AccountType: String, Codable, Sendable, CaseIterable {
    case checking
    case savings
    case cash
    case creditCard
    case lineOfCredit
    case otherAsset
    case otherLiability
    case investment

    /// Budget accounts hold money the envelope budget assigns; tracking accounts only affect net worth.
    public var belongsOnBudgetByDefault: Bool {
        switch self {
        case .checking, .savings, .cash, .creditCard, .lineOfCredit: true
        case .otherAsset, .otherLiability, .investment: false
        }
    }

    /// Whether an entry here is settled the moment it is written.
    ///
    /// Clearing exists so a transaction can be recorded now and confirmed later against what the
    /// bank says — the amount on a card statement, a cheque that has not landed. Cash has no
    /// statement and no later: handing over a note is the whole event. YNAB marks cash this way too.
    public var settlesImmediately: Bool { self == .cash }

    /// Credit accounts get an auto-managed payment category, which changes the carryover rules.
    public var isCredit: Bool {
        self == .creditCard || self == .lineOfCredit
    }

    public var isLiability: Bool {
        switch self {
        case .creditCard, .lineOfCredit, .otherLiability: true
        case .checking, .savings, .cash, .otherAsset, .investment: false
        }
    }
}

public enum CategoryKind: String, Codable, Sendable {
    /// A normal spending or saving envelope.
    case normal
    /// The single internal inflow bucket ("Inflow: Ready to Assign").
    case inflowReadyToAssign
    /// Auto-managed, one per credit account: holds the money set aside to pay that card.
    case creditCardPayment
}

public enum ClearedStatus: String, Codable, Sendable {
    case uncleared
    case cleared
    case reconciled
}

public struct BudgetAccount: Identifiable, Hashable, Sendable {
    public let id: EntityID
    public var name: String
    public var type: AccountType
    public var onBudget: Bool
    public var closed: Bool

    public init(
        id: EntityID = UUID(),
        name: String,
        type: AccountType,
        onBudget: Bool? = nil,
        closed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.onBudget = onBudget ?? type.belongsOnBudgetByDefault
        self.closed = closed
    }
}

public struct BudgetCategory: Identifiable, Hashable, Sendable {
    public let id: EntityID
    public var name: String
    public var groupName: String
    public var kind: CategoryKind
    /// Set for `.creditCardPayment` categories: the credit account they service.
    public var linkedAccountID: EntityID?
    public var hidden: Bool

    public init(
        id: EntityID = UUID(),
        name: String,
        groupName: String,
        kind: CategoryKind = .normal,
        linkedAccountID: EntityID? = nil,
        hidden: Bool = false
    ) {
        self.id = id
        self.name = name
        self.groupName = groupName
        self.kind = kind
        self.linkedAccountID = linkedAccountID
        self.hidden = hidden
    }
}

/// A leaf money movement. Split transactions are fed to the engine as their subtransactions, never
/// as a parent plus children, so summing entries never double-counts.
public struct BudgetEntry: Identifiable, Hashable, Sendable {
    public let id: EntityID
    public var accountID: EntityID
    public var date: Date
    public var categoryID: EntityID?
    /// Signed, in plan base currency minor units. Negative is an outflow.
    public var amount: MinorUnits
    /// Set when this entry is one side of a transfer; identifies the other account.
    public var transferCounterAccountID: EntityID?
    /// Scheduled, and not yet confirmed by the person. Whatever its date, it has not happened: a
    /// subscription cancelled in the meantime must not be spent from the plan because its day came.
    public var awaitsApproval: Bool

    public init(
        id: EntityID = UUID(),
        accountID: EntityID,
        date: Date,
        categoryID: EntityID? = nil,
        amount: MinorUnits,
        transferCounterAccountID: EntityID? = nil,
        awaitsApproval: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        self.date = date
        self.categoryID = categoryID
        self.amount = amount
        self.transferCounterAccountID = transferCounterAccountID
        self.awaitsApproval = awaitsApproval
    }

    public var isTransfer: Bool { transferCounterAccountID != nil }

    /// Whether this has moved money as of `asOf`: dated on or before it, and approved. Pass nil to
    /// count every approved entry whatever its date.
    public func hasHappened(asOf: Date?) -> Bool {
        guard !awaitsApproval else { return false }
        guard let asOf else { return true }
        return date <= asOf
    }
}

public struct BudgetAssignment: Hashable, Sendable {
    public var categoryID: EntityID
    public var month: YearMonth
    public var amount: MinorUnits

    public init(categoryID: EntityID, month: YearMonth, amount: MinorUnits) {
        self.categoryID = categoryID
        self.month = month
        self.amount = amount
    }
}

public struct BudgetInput: Sendable {
    public var accounts: [BudgetAccount]
    public var categories: [BudgetCategory]
    public var entries: [BudgetEntry]
    public var assignments: [BudgetAssignment]

    public init(
        accounts: [BudgetAccount] = [],
        categories: [BudgetCategory] = [],
        entries: [BudgetEntry] = [],
        assignments: [BudgetAssignment] = []
    ) {
        self.accounts = accounts
        self.categories = categories
        self.entries = entries
        self.assignments = assignments
    }
}
