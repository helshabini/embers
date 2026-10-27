import Foundation
import EmbersCore
import SwiftData

/// A whole budget, serialised.
///
/// Plain JSON rather than a copy of the store file: a store is tied to a schema version and an OS
/// release, while this stays readable and restorable after either moves on. It is also legible
/// enough to inspect by hand, which matters for the only copy of seven years of records.
public struct BackupArchive: Codable, Sendable {
    public static let currentFormatVersion = 1

    public struct AccountRecord: Codable, Sendable {
        public var id: UUID
        public var name: String
        public var type: AccountType
        public var currencyCode: String
        public var fxFeePercentOverride: Double?
        public var onBudget: Bool
        public var closed: Bool
        public var order: Int
        public var notes: String
    }

    public struct PayeeRecord: Codable, Sendable {
        public var id: UUID
        public var name: String
    }

    public struct GroupRecord: Codable, Sendable {
        public var id: UUID
        public var name: String
        public var order: Int
        public var hidden: Bool
        public var isSystemManaged: Bool
    }

    public struct CategoryRecord: Codable, Sendable {
        public var id: UUID
        public var name: String
        public var groupID: UUID?
        public var order: Int
        public var hidden: Bool
        public var notes: String
        public var kind: CategoryKind
        public var linkedAccountID: UUID?
    }

    public struct AssignmentRecord: Codable, Sendable {
        public var categoryID: UUID
        public var monthOrdinal: Int
        public var amountMinor: Int
    }

    public struct TransactionRecord: Codable, Sendable {
        public var id: UUID
        public var accountID: UUID?
        public var date: Date
        public var amountMinor: Int
        public var memo: String
        public var cleared: ClearedStatus
        public var flag: FlagColor?
        public var payeeID: UUID?
        public var categoryID: UUID?
        public var transferCounterAccountID: UUID?
        public var transferPairIdentifier: UUID?
        public var parentID: UUID?
        public var conversion: CurrencyConversion?
        /// How the entry repeats, if it does. Optional so that backups written before this field
        /// existed still read — they simply have no schedules to restore.
        public var recurrence: Recurrence?
        /// When it was entered, which orders a day's entries newest first. Optional for the same
        /// reason; older backups fall back to their own order — see `restore`.
        public var createdAt: Date?
        /// Waiting to be approved. Optional so older backups still read; a future entry from one is
        /// marked again by the launch audit, and one already due simply counts, as it did then.
        public var awaitsApproval: Bool?
    }

    public var formatVersion: Int = BackupArchive.currentFormatVersion
    public var createdAt: Date
    public var planName: String
    public var baseCurrencyCode: String
    public var defaultFXFeePercent: Double
    public var accounts: [AccountRecord]
    public var payees: [PayeeRecord]
    public var groups: [GroupRecord]
    public var categories: [CategoryRecord]
    public var assignments: [AssignmentRecord]
    public var transactions: [TransactionRecord]

    public var summary: String {
        [
            Counted.accounts(accounts.count),
            Counted.transactions(transactions.count),
            Counted.categories(categories.count),
        ].joined(separator: " · ")
    }
}

public enum BackupError: Error, CustomStringConvertible {
    case unsupportedFormat(Int)

    public var description: String {
        switch self {
        case let .unsupportedFormat(version):
            String(
                localized: "This backup was written by a newer version of Embers (format \(version)).",
                bundle: .module,
                locale: .display
            )
        }
    }
}

@MainActor
public enum BackupWriter {
    public static func archive(from context: ModelContext) throws -> BackupArchive {
        let settings = try context.planSettings()
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let payees = try context.fetch(FetchDescriptor<Payee>())
        let groups = try context.fetch(FetchDescriptor<CategoryGroup>())
        let categories = try context.fetch(FetchDescriptor<BudgetCategoryModel>())
        let assignments = try context.fetch(FetchDescriptor<CategoryAssignment>())
        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())

        return BackupArchive(
            createdAt: Date(),
            planName: settings.name,
            baseCurrencyCode: settings.baseCurrencyCode,
            defaultFXFeePercent: settings.defaultFXFeePercent,
            accounts: accounts.map {
                .init(
                    id: $0.identifier, name: $0.name, type: $0.type, currencyCode: $0.currencyCode,
                    fxFeePercentOverride: $0.fxFeePercentOverride, onBudget: $0.onBudget,
                    closed: $0.closed, order: $0.order, notes: $0.notes
                )
            },
            payees: payees.map { .init(id: $0.identifier, name: $0.name) },
            groups: groups.map {
                .init(
                    id: $0.identifier, name: $0.name, order: $0.order,
                    hidden: $0.hidden, isSystemManaged: $0.isSystemManaged
                )
            },
            categories: categories.map {
                .init(
                    id: $0.identifier, name: $0.name, groupID: $0.group?.identifier,
                    order: $0.order, hidden: $0.hidden, notes: $0.notes, kind: $0.kind,
                    linkedAccountID: $0.linkedAccount?.identifier
                )
            },
            assignments: assignments.compactMap { assignment in
                guard let categoryID = assignment.category?.identifier else { return nil }
                return .init(
                    categoryID: categoryID,
                    monthOrdinal: assignment.monthOrdinal,
                    amountMinor: assignment.amountMinor
                )
            },
            transactions: transactions.map {
                .init(
                    id: $0.identifier, accountID: $0.account?.identifier, date: $0.date,
                    amountMinor: $0.amountMinor, memo: $0.memo, cleared: $0.cleared, flag: $0.flag,
                    payeeID: $0.payee?.identifier, categoryID: $0.category?.identifier,
                    transferCounterAccountID: $0.transferCounterAccount?.identifier,
                    transferPairIdentifier: $0.transferPairIdentifier,
                    parentID: $0.parent?.identifier, conversion: $0.conversion,
                    recurrence: $0.recurrence, createdAt: $0.createdAt,
                    // Written only when set: ten thousand "false" lines say nothing.
                    awaitsApproval: $0.awaitsApproval ? true : nil
                )
            }
        )
    }

    public static func data(from context: ModelContext) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(try archive(from: context))
    }

    public static func decode(_ data: Data) throws -> BackupArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(BackupArchive.self, from: data)
        guard archive.formatVersion <= BackupArchive.currentFormatVersion else {
            throw BackupError.unsupportedFormat(archive.formatVersion)
        }
        return archive
    }

    /// Replaces everything in the store with the archive's contents.
    public static func restore(_ archive: BackupArchive, into context: ModelContext) throws {
        try write(archive, into: context)
        try finishRestoring(in: context)
    }

    /// The bulk of a restore: clearing the store and writing the archive in.
    ///
    /// Not on the main actor, so a screen can hand it a context of its own. Ten thousand deletes
    /// and as many inserts on the main actor froze the app for seconds with nothing to show for it.
    nonisolated public static func write(_ archive: BackupArchive, into context: ModelContext) throws {
        try ImportWriter.deleteAllPlanData(in: context)

        let settings = try context.planSettings()
        settings.name = archive.planName
        settings.baseCurrencyCode = archive.baseCurrencyCode
        settings.defaultFXFeePercent = archive.defaultFXFeePercent

        var accountsByID: [UUID: Account] = [:]
        for record in archive.accounts {
            let account = Account(
                identifier: record.id, name: record.name, type: record.type,
                currencyCode: record.currencyCode,
                fxFeePercentOverride: record.fxFeePercentOverride,
                onBudget: record.onBudget, closed: record.closed,
                order: record.order, notes: record.notes
            )
            context.insert(account)
            accountsByID[record.id] = account
        }

        var payeesByID: [UUID: Payee] = [:]
        for record in archive.payees {
            let payee = Payee(identifier: record.id, name: record.name)
            context.insert(payee)
            payeesByID[record.id] = payee
        }

        var groupsByID: [UUID: CategoryGroup] = [:]
        for record in archive.groups {
            let group = CategoryGroup(
                identifier: record.id, name: record.name, order: record.order,
                hidden: record.hidden, isSystemManaged: record.isSystemManaged
            )
            context.insert(group)
            groupsByID[record.id] = group
        }

        var categoriesByID: [UUID: BudgetCategoryModel] = [:]
        for record in archive.categories {
            let category = BudgetCategoryModel(
                identifier: record.id, name: record.name,
                group: record.groupID.flatMap { groupsByID[$0] },
                order: record.order, hidden: record.hidden, kind: record.kind,
                linkedAccount: record.linkedAccountID.flatMap { accountsByID[$0] }
            )
            category.notes = record.notes
            context.insert(category)
            categoriesByID[record.id] = category
        }

        for record in archive.assignments {
            guard let category = categoriesByID[record.categoryID] else { continue }
            context.insert(
                CategoryAssignment(
                    month: YearMonth(ordinal: record.monthOrdinal),
                    amountMinor: record.amountMinor,
                    category: category
                )
            )
        }

        // Two passes: every transaction must exist before split lines can point at their parent.
        var transactionsByID: [UUID: LedgerTransaction] = [:]
        let count = archive.transactions.count
        for (index, record) in archive.transactions.enumerated() {
            let transaction = LedgerTransaction(
                identifier: record.id, date: record.date, amountMinor: record.amountMinor,
                memo: record.memo, cleared: record.cleared, flag: record.flag,
                account: record.accountID.flatMap { accountsByID[$0] },
                payee: record.payeeID.flatMap { payeesByID[$0] },
                category: record.categoryID.flatMap { categoriesByID[$0] },
                transferCounterAccount: record.transferCounterAccountID.flatMap { accountsByID[$0] },
                conversion: record.conversion
            )
            transaction.transferPairIdentifier = record.transferPairIdentifier
            transaction.recurrence = record.recurrence
            transaction.awaitsApproval = record.awaitsApproval ?? false
            // A backup without entry times is in the order the store handed them out, which is the
            // order they were entered. Spacing them a millisecond apart, ending when the backup was
            // taken, keeps a day's entries in that order instead of all sharing one restore instant.
            transaction.createdAt = record.createdAt
                ?? archive.createdAt.addingTimeInterval(Double(index - count) / 1000)
            context.insert(transaction)
            transactionsByID[record.id] = transaction
        }
        for record in archive.transactions {
            guard let parentID = record.parentID else { continue }
            transactionsByID[record.id]?.parent = transactionsByID[parentID]
        }

        try context.save()
    }

    /// What a restore does after `write`, on the main actor where the transfer writer lives.
    public static func finishRestoring(in context: ModelContext) throws {
        // A backup written before transfers were paired restores two unrelated rows per transfer.
        // This is where that can still happen, so it is mended on the way in.
        try TransferWriter.repairUnpairedTransfers(in: context)
    }

    /// A filename that sorts chronologically and says what it holds.
    public static func suggestedFileName(for archive: BackupArchive) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .gregorianUTC
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "Embers Backup \(formatter.string(from: archive.createdAt)).embers.json"
    }
}
