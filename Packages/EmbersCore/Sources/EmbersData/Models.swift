import Foundation
import EmbersCore
import SwiftData

// CloudKit's mirrored schema imposes rules that shape every model here: no unique constraints, every
// stored property needs a default or must be optional, and every relationship needs an inverse and
// must be optional. Money is stored as integer minor units in the plan's base currency.

/// The single row holding plan-wide settings. One plan exists at a time; "Start Fresh" archives the
/// old one and replaces it, so there is no plan-switching relationship graph.
@Model
public final class PlanSettings {
    public var name: String = "My Budget"
    public var baseCurrencyCode: String = "USD"
    /// The bank's default foreign-transaction fee, as a percentage. Accounts may override it.
    public var defaultFXFeePercent: Double = 0
    public var createdAt: Date = Date()
    public var rateProviderName: String = "open.er-api.com"

    public init(
        name: String = "My Budget",
        baseCurrencyCode: String = "USD",
        defaultFXFeePercent: Double = 0,
        createdAt: Date = Date()
    ) {
        self.name = name
        self.baseCurrencyCode = baseCurrencyCode
        self.defaultFXFeePercent = defaultFXFeePercent
        self.createdAt = createdAt
    }

    public var baseCurrency: Currency {
        CurrencyRegistry.currency(forCode: baseCurrencyCode)
    }
}

@Model
public final class Account {
    public var identifier: UUID = UUID()
    public var name: String = ""
    public var type: AccountType = AccountType.checking
    /// The account's own currency. Drives whether an FX fee applies and the default entry currency.
    public var currencyCode: String = "USD"
    /// Overrides the plan's default fee for this account, when its bank charges something different.
    public var fxFeePercentOverride: Double?
    public var onBudget: Bool = true
    public var closed: Bool = false
    public var order: Int = 0
    public var notes: String = ""
    public var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \LedgerTransaction.account)
    public var transactions: [LedgerTransaction]? = []

    // The far ends of two relationships that point here. Nothing reads them; they exist because
    // CloudKit refuses to open a store with a relationship lacking an inverse — it named exactly
    // these two the first time syncing was switched on. Accounts are closed rather than deleted,
    // so the nullify never runs in practice.
    @Relationship(deleteRule: .nullify, inverse: \BudgetCategoryModel.linkedAccount)
    public var paymentCategories: [BudgetCategoryModel]? = []
    @Relationship(deleteRule: .nullify, inverse: \LedgerTransaction.transferCounterAccount)
    public var transfersFromElsewhere: [LedgerTransaction]? = []

    public init(
        identifier: UUID = UUID(),
        name: String,
        type: AccountType,
        currencyCode: String = "USD",
        fxFeePercentOverride: Double? = nil,
        onBudget: Bool? = nil,
        closed: Bool = false,
        order: Int = 0,
        notes: String = ""
    ) {
        self.identifier = identifier
        self.name = name
        self.type = type
        self.currencyCode = currencyCode
        self.fxFeePercentOverride = fxFeePercentOverride
        self.onBudget = onBudget ?? type.belongsOnBudgetByDefault
        self.closed = closed
        self.order = order
        self.notes = notes
    }

    public var currency: Currency {
        CurrencyRegistry.currency(forCode: currencyCode)
    }
}

@Model
public final class Payee {
    public var identifier: UUID = UUID()
    public var name: String = ""
    public var lastUsedAt: Date?
    public var notes: String = ""

    @Relationship(deleteRule: .nullify, inverse: \LedgerTransaction.payee)
    public var transactions: [LedgerTransaction]? = []

    public init(identifier: UUID = UUID(), name: String, lastUsedAt: Date? = nil) {
        self.identifier = identifier
        self.name = name
        self.lastUsedAt = lastUsedAt
    }
}

@Model
public final class CategoryGroup {
    public var identifier: UUID = UUID()
    public var name: String = ""
    public var order: Int = 0
    public var hidden: Bool = false
    /// True for groups the app manages itself, such as Credit Card Payments.
    public var isSystemManaged: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \BudgetCategoryModel.group)
    public var categories: [BudgetCategoryModel]? = []

    public init(
        identifier: UUID = UUID(),
        name: String,
        order: Int = 0,
        hidden: Bool = false,
        isSystemManaged: Bool = false
    ) {
        self.identifier = identifier
        self.name = name
        self.order = order
        self.hidden = hidden
        self.isSystemManaged = isSystemManaged
    }
}

/// Named to avoid colliding with `EmbersCore.BudgetCategory`, the value type the engine consumes.
@Model
public final class BudgetCategoryModel {
    public var identifier: UUID = UUID()
    public var name: String = ""
    public var order: Int = 0
    public var hidden: Bool = false
    public var notes: String = ""
    public var kind: CategoryKind = CategoryKind.normal

    public var group: CategoryGroup?
    /// Set for credit card payment categories: the card they service.
    public var linkedAccount: Account?

    /// Target ("needed this month") settings, all optional until the user sets one.
    public var targetKind: TargetKind?
    public var targetAmountMinor: Int?
    public var targetDueDate: Date?

    @Relationship(deleteRule: .nullify, inverse: \LedgerTransaction.category)
    public var transactions: [LedgerTransaction]? = []

    @Relationship(deleteRule: .cascade, inverse: \CategoryAssignment.category)
    public var assignments: [CategoryAssignment]? = []

    public init(
        identifier: UUID = UUID(),
        name: String,
        group: CategoryGroup? = nil,
        order: Int = 0,
        hidden: Bool = false,
        kind: CategoryKind = .normal,
        linkedAccount: Account? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.group = group
        self.order = order
        self.hidden = hidden
        self.kind = kind
        self.linkedAccount = linkedAccount
    }
}

public enum TargetKind: String, Codable, Sendable, CaseIterable {
    /// Spend this much in the period.
    case neededForSpending
    /// Reach this balance by a date.
    case savingsBalanceByDate
    /// Add this much every month, indefinitely.
    case monthlySavingsBuilder
}

/// One change to what a category has assigned in a month; the cell is the sum of its rows. See
/// `AssignmentWriter` for why a change is stored rather than the total.
@Model
public final class CategoryAssignment {
    public var identifier: UUID = UUID()
    /// `YearMonth.ordinal`, so months sort and compare as integers in predicates.
    public var monthOrdinal: Int = 0
    public var amountMinor: Int = 0
    public var category: BudgetCategoryModel?

    public init(
        identifier: UUID = UUID(),
        month: YearMonth,
        amountMinor: Int,
        category: BudgetCategoryModel? = nil
    ) {
        self.identifier = identifier
        self.monthOrdinal = month.ordinal
        self.amountMinor = amountMinor
        self.category = category
    }

    public var month: YearMonth {
        get { YearMonth(ordinal: monthOrdinal) }
        set { monthOrdinal = newValue.ordinal }
    }
}

public enum FlagColor: String, Codable, Sendable, CaseIterable {
    case red, orange, yellow, green, blue, purple
}

@Model
public final class LedgerTransaction {
    public var identifier: UUID = UUID()
    public var date: Date = Date()
    /// Signed minor units in the plan's base currency. Negative is an outflow.
    public var amountMinor: Int = 0
    public var memo: String = ""
    /// Stored as its raw value: a property named `cleared` holding an enum with a `.cleared` case
    /// does not round-trip through SwiftData — every row read back as `.cleared` regardless of what
    /// was written, which silently made every register look fully reconciled.
    public var clearedRaw: String = ClearedStatus.uncleared.rawValue
    public var flag: FlagColor?
    public var createdAt: Date = Date()

    public var account: Account?
    public var payee: Payee?
    public var category: BudgetCategoryModel?

    /// The other account in a transfer. Both sides are real entries in their own registers.
    public var transferCounterAccount: Account?
    public var transferPairIdentifier: UUID?

    /// Set on the lines of a split; the parent itself carries no category.
    public var parent: LedgerTransaction?

    @Relationship(deleteRule: .cascade, inverse: \LedgerTransaction.parent)
    public var splitLines: [LedgerTransaction]? = []

    /// What the user typed when entering in a different currency, with the rate and fee applied.
    public var conversion: CurrencyConversion?

    /// Identifies rows brought in from an import, so a re-import can recognise them.
    public var importKey: String?

    /// Set when this entry is the next occurrence of a repeating transaction.
    public var recurrence: Recurrence?

    /// The entry this one was copied forward from, when a repeat entered its next occurrence. Two
    /// devices that each roll the same repeat forward make two copies of one payment; this is how
    /// `SyncMerge` knows them for the same one.
    public var occurrenceOf: UUID?

    /// On a reconciliation adjustment: the account, day, statement balance and cleared balance it
    /// was worked out from. Two devices reconciling the same account against the same statement each
    /// write one, and the balance ends up adjusted twice; identical keys are how `SyncMerge` finds
    /// them. A second reconciliation on the same day starts from a cleared balance that already
    /// holds the first adjustment, so its key differs.
    public var reconciliationKey: String?

    /// Entered ahead of its date, and not yet confirmed. Set on everything dated after today
    /// (`RecurrenceWriter.markScheduled`); when the day comes the entry still counts for nothing
    /// until the person approves it, because the payment may have been cancelled in the meantime.
    /// Letting due entries count on their own spent a cancelled subscription without anyone noticing.
    public var awaitsApproval: Bool = false

    public init(
        identifier: UUID = UUID(),
        date: Date,
        amountMinor: Int,
        memo: String = "",
        cleared: ClearedStatus = .uncleared,
        flag: FlagColor? = nil,
        account: Account? = nil,
        payee: Payee? = nil,
        category: BudgetCategoryModel? = nil,
        transferCounterAccount: Account? = nil,
        parent: LedgerTransaction? = nil,
        conversion: CurrencyConversion? = nil,
        importKey: String? = nil
    ) {
        self.identifier = identifier
        self.date = date
        self.amountMinor = amountMinor
        self.memo = memo
        self.clearedRaw = cleared.rawValue
        self.flag = flag
        self.account = account
        self.payee = payee
        self.category = category
        self.transferCounterAccount = transferCounterAccount
        self.parent = parent
        self.conversion = conversion
        self.importKey = importKey
    }

    public var cleared: ClearedStatus {
        get { ClearedStatus(rawValue: clearedRaw) ?? .uncleared }
        set { clearedRaw = newValue.rawValue }
    }

    public var isSplitParent: Bool { !(splitLines ?? []).isEmpty }
    public var isTransfer: Bool { transferCounterAccount != nil }
}

@Model
public final class ExchangeRateSnapshot {
    public var identifier: UUID = UUID()
    public var baseCode: String = "USD"
    public var asOf: Date = Date()
    public var providerName: String = ""
    /// Rates as JSON. A dictionary attribute would not survive the CloudKit schema.
    public var ratesJSON: String = "{}"

    public init(quote: ExchangeRateQuote) {
        self.identifier = UUID()
        self.baseCode = quote.baseCode
        self.asOf = quote.asOf
        self.providerName = quote.providerName
        self.ratesJSON = (try? String(data: JSONEncoder().encode(quote.rates), encoding: .utf8) ?? "{}") ?? "{}"
    }

    public var quote: ExchangeRateQuote {
        let rates = (try? JSONDecoder().decode(
            [String: Double].self,
            from: Data(ratesJSON.utf8)
        )) ?? [:]
        return ExchangeRateQuote(
            baseCode: baseCode,
            asOf: asOf,
            providerName: providerName,
            rates: rates
        )
    }
}

public enum BackupReason: String, Codable, Sendable {
    case startFresh
    case manual
    case beforeImport
}

@Model
public final class BackupRecord {
    public var identifier: UUID = UUID()
    public var createdAt: Date = Date()
    public var reason: BackupReason = BackupReason.manual
    public var fileName: String = ""
    public var accountCount: Int = 0
    public var transactionCount: Int = 0
    public var summary: String = ""

    public init(
        reason: BackupReason,
        fileName: String,
        accountCount: Int = 0,
        transactionCount: Int = 0,
        summary: String = ""
    ) {
        self.identifier = UUID()
        self.createdAt = Date()
        self.reason = reason
        self.fileName = fileName
        self.accountCount = accountCount
        self.transactionCount = transactionCount
        self.summary = summary
    }
}
