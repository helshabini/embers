import Foundation
import EmbersCore
import SwiftData

/// Folds together what two devices each made for themselves before they had heard from each other.
///
/// CloudKit has no unique constraints, so nothing stops two devices that are each "the only copy"
/// from making the same thing: a new iPad seeds starter groups and a credit card group while the
/// phone's are still on their way, both devices roll the same repeat forward, both reconcile the same account, both meet the same new payee. Each of these is found
/// here by what it *is* — a group's name, a card's category, an occurrence, a payee's name, a
/// reconciliation — and folded into one.
///
/// **Every device must pick the same survivor**, or each deletes the other's and both are lost. So the
/// survivor is chosen by identifier alone, never by which one holds more, which can differ between
/// devices partway through a sync.
///
/// **A duplicate group, category or payee is emptied and hidden, never deleted.** A group's deletion
/// cascades to its categories, a category's and a payee's clear themselves off their transactions,
/// and a device that receives the deletion before the moves applies it to rows it still holds — then
/// sends that out too. No device can know when every other has the moves, so no later run is safe
/// either. This used to delete what it had emptied "on a later run"; runs follow every import, and
/// on a new Mac the later run came in the same second. Its iPhone received seven groups' deletions
/// ahead of the moves and left 5,900 transactions without a category. A hidden duplicate costs a
/// line under Hidden Categories.
@MainActor
public enum SyncMerge {
    public struct Merges: Sendable, Equatable {
        public var settingsRemoved = 0
        public var groupsFolded = 0
        public var categoriesFolded = 0
        /// Assignment rows removed because the category's other copy already held the same one.
        public var duplicateAssignmentsRemoved = 0
        public var occurrencesRemoved = 0
        public var payeesFolded = 0
        public var adjustmentsRemoved = 0

        public init() {}

        public var didChangeAnything: Bool {
            settingsRemoved + groupsFolded + categoriesFolded + duplicateAssignmentsRemoved
                + occurrencesRemoved + payeesFolded + adjustmentsRemoved > 0
        }
    }

    @discardableResult
    public static func mergeDuplicates(in context: ModelContext) throws -> Merges {
        var merges = Merges()
        merges.settingsRemoved = try mergeSettings(in: context)
        try foldSameCategory(in: context, into: &merges)
        try foldGroups(in: context, into: &merges)
        try foldCategories(in: context, into: &merges)
        merges.occurrencesRemoved = try removeDuplicateOccurrences(in: context)
        try foldPayees(in: context, into: &merges)
        merges.adjustmentsRemoved = try removeDuplicateAdjustments(in: context)
        if context.hasChanges { try context.save() }
        return merges
    }

    // MARK: - Settings

    /// The oldest settings are the plan's; a younger row is a device's default from before the plan
    /// arrived. Settings hold nothing, so the others go at once.
    private static func mergeSettings(in context: ModelContext) throws -> Int {
        let all = try context.fetch(FetchDescriptor<PlanSettings>())
        guard all.count > 1 else { return 0 }
        let ordered = all.sorted {
            ($0.createdAt, $0.baseCurrencyCode, $0.name) < ($1.createdAt, $1.baseCurrencyCode, $1.name)
        }
        for extra in ordered.dropFirst() { context.delete(extra) }
        return ordered.count - 1
    }

    // MARK: - Groups and categories

    /// One category held twice under its own identifier.
    ///
    /// A restore writes every category again under the identifier it was backed up with, and deletes
    /// what was there. A copy whose deletion never reached iCloud — one a device had already lost,
    /// so had nothing to delete — stays there beside the restored one, and every device that
    /// downloads from scratch receives both. A new Mac did: 44 categories twice, the stale copies with
    /// no group and 406 assignment rows each matching one on the restored copy, and its budget
    /// engine stopped on the repeated identifier at every launch.
    ///
    /// The copy kept is `canonicalCategory`. The other's transactions move to it; its assignment rows
    /// that match one the kept copy already has (month and amount) are the same money twice and go;
    /// any others move. It is then hidden, not deleted (see the type's note).
    private static func foldSameCategory(in context: ModelContext, into merges: inout Merges) throws {
        let categories = try context.fetch(FetchDescriptor<BudgetCategoryModel>())
        for copies in Dictionary(grouping: categories, by: \.identifier).values where copies.count > 1 {
            let survivor = canonicalCategory(copies)
            // Each of the kept copy's rows can account for one matching row on another copy.
            var held: [AssignmentKey: Int] = [:]
            for assignment in survivor.assignments ?? [] { held[AssignmentKey(assignment), default: 0] += 1 }

            for loser in copies where loser !== survivor {
                let transactions = loser.transactions ?? []
                let assignments = loser.assignments ?? []
                guard !transactions.isEmpty || !assignments.isEmpty else {
                    if !loser.hidden { loser.hidden = true }
                    continue
                }
                for transaction in transactions { transaction.category = survivor }
                for assignment in assignments {
                    let key = AssignmentKey(assignment)
                    if let count = held[key], count > 0 {
                        held[key] = count - 1
                        context.delete(assignment)
                        merges.duplicateAssignmentsRemoved += 1
                    } else {
                        assignment.category = survivor
                    }
                }
                loser.hidden = true
                merges.categoriesFolded += 1
            }
        }
    }

    private struct AssignmentKey: Hashable {
        let month: Int
        let amount: Int

        init(_ assignment: CategoryAssignment) {
            month = assignment.monthOrdinal
            amount = assignment.amountMinor
        }
    }

    /// Which of several rows sharing one identifier stands for the category: the one in a group, then
    /// the one on the plan. Read by the budget too, so the figures and the merge agree on it before
    /// the merge has run.
    public nonisolated static func canonicalCategory(_ copies: [BudgetCategoryModel]) -> BudgetCategoryModel {
        copies.min { lhs, rhs in
            (lhs.group == nil ? 1 : 0, lhs.hidden ? 1 : 0, lhs.group?.identifier.uuidString ?? "")
                < (rhs.group == nil ? 1 : 0, rhs.hidden ? 1 : 0, rhs.group?.identifier.uuidString ?? "")
        }!
    }

    /// Groups of the same name. The app refuses a second group by a name already used, so two can
    /// only have come from two devices.
    private static func foldGroups(in context: ModelContext, into merges: inout Merges) throws {
        let groups = try context.fetch(FetchDescriptor<CategoryGroup>())
        let byName = Dictionary(grouping: groups) { $0.name.lowercased() }
        for duplicates in byName.values where duplicates.count > 1 {
            let survivor = lowest(duplicates)
            for loser in duplicates where loser !== survivor {
                let categories = loser.categories ?? []
                // Emptied already, or nothing here yet: hidden, and left. See the type's note.
                guard !categories.isEmpty else {
                    if !loser.hidden { loser.hidden = true }
                    continue
                }
                for category in categories { category.group = survivor }
                survivor.isSystemManaged = survivor.isSystemManaged || loser.isSystemManaged
                survivor.hidden = survivor.hidden && loser.hidden
                loser.hidden = true
                merges.groupsFolded += 1
            }
        }
    }

    /// A card's payment categories, and same-named categories in one group.
    ///
    /// Hidden Categories is left alone: two categories hidden from different groups can share a name
    /// and still be two envelopes with their own history.
    private static func foldCategories(in context: ModelContext, into merges: inout Merges) throws {
        let categories = try context.fetch(FetchDescriptor<BudgetCategoryModel>())
        let buckets = Dictionary(grouping: categories) { category -> String? in
            switch category.kind {
            case .creditCardPayment:
                return category.linkedAccount.map { "card:\($0.identifier)" }
            case .normal:
                guard let group = category.group,
                      group.name.caseInsensitiveCompare(CategoryWriter.hiddenGroupName) != .orderedSame
                else { return nil }
                return "name:\(group.identifier):\(category.name.lowercased())"
            case .inflowReadyToAssign:
                return "inflow"
            }
        }
        for (key, duplicates) in buckets where key != nil && duplicates.count > 1 {
            let survivor = lowest(duplicates)
            for loser in duplicates where loser !== survivor {
                let transactions = loser.transactions ?? []
                let assignments = loser.assignments ?? []
                // Emptied already, or its history not arrived yet: hidden, and left.
                guard !transactions.isEmpty || !assignments.isEmpty else {
                    if !loser.hidden { loser.hidden = true }
                    continue
                }
                // Each row is a change, so the two envelopes' months add up by moving the rows.
                for transaction in transactions { transaction.category = survivor }
                for assignment in assignments { assignment.category = survivor }
                loser.hidden = true
                merges.categoriesFolded += 1
            }
        }
    }

    // MARK: - Repeats

    /// Two copies of one repeat's next occurrence.
    ///
    /// One already approved is a payment that happened, and stays; the copies still waiting go. Two
    /// approved are both left: each was confirmed by the person, and only they know whether it went
    /// out twice. Among copies all waiting, the lowest pair is kept — by the pair's identifier, so
    /// both sides of a transfer agree on which pair that is.
    private static func removeDuplicateOccurrences(in context: ModelContext) throws -> Int {
        let copies = try context.fetch(
            FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.occurrenceOf != nil })
        )
        func pairKey(_ transaction: LedgerTransaction) -> String {
            (transaction.transferPairIdentifier ?? transaction.identifier).uuidString
        }

        var removed = Set<UUID>()
        for rows in Dictionary(grouping: copies, by: { $0.occurrenceOf }).values {
            let pairs = Set(rows.map(pairKey))
            guard pairs.count > 1 else { continue }
            let approved = Set(rows.filter { !$0.awaitsApproval }.map(pairKey))
            let kept = approved.isEmpty ? [pairs.min()!] : approved
            for row in rows where !kept.contains(pairKey(row)) && row.awaitsApproval {
                for side in try TransferWriter.pair(of: row, in: context)
                where !removed.contains(side.identifier) {
                    removed.insert(side.identifier)
                    context.delete(side)
                }
            }
        }
        return removed.count
    }

    // MARK: - Payees

    /// Payees of the same name. The editor reuses a payee whose name matches what was typed, so two
    /// can only come from two devices that each met it first. Emptied, never deleted: a payee's
    /// deletion nullifies its entries, and a device yet to hear of the move would clear the payee
    /// off them. Suggestions and the editor both prefer the survivor, so the emptied one goes unused.
    private static func foldPayees(in context: ModelContext, into merges: inout Merges) throws {
        let payees = try context.fetch(FetchDescriptor<Payee>())
        let byName = Dictionary(grouping: payees) {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        for duplicates in byName.values where duplicates.count > 1 {
            let survivor = lowest(duplicates)
            for loser in duplicates where loser !== survivor {
                let transactions = loser.transactions ?? []
                guard !transactions.isEmpty else { continue }
                for transaction in transactions { transaction.payee = survivor }
                if let used = loser.lastUsedAt, used > survivor.lastUsedAt ?? .distantPast {
                    survivor.lastUsedAt = used
                }
                merges.payeesFolded += 1
            }
        }
    }

    /// One payee per name: the one `foldPayees` keeps. Two devices that each met a payee leave two;
    /// the emptied one is never deleted, so whatever offers payees by name offers this one.
    public nonisolated static func survivingPayees(_ payees: [Payee]) -> [Payee] {
        Dictionary(grouping: payees) { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .values
            .map { $0.min { $0.identifier.uuidString < $1.identifier.uuidString }! }
    }

    // MARK: - Reconciliation

    /// One reconciliation made on two devices: the same adjustment twice, so the account is out by
    /// exactly that amount. The lowest is kept.
    private static func removeDuplicateAdjustments(in context: ModelContext) throws -> Int {
        let adjustments = try context.fetch(
            FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.reconciliationKey != nil })
        )
        var removed = 0
        for rows in Dictionary(grouping: adjustments, by: { $0.reconciliationKey }).values
        where rows.count > 1 {
            let kept = rows.min { $0.identifier.uuidString < $1.identifier.uuidString }
            for row in rows where row !== kept {
                context.delete(row)
                removed += 1
            }
        }
        return removed
    }

    private static func lowest<Model: AnyObject>(_ models: [Model]) -> Model
    where Model: Identified {
        models.min { $0.identifier.uuidString < $1.identifier.uuidString }!
    }
}

/// What `SyncMerge` orders survivors by.
protocol Identified {
    var identifier: UUID { get }
}

extension CategoryGroup: Identified {}
extension BudgetCategoryModel: Identified {}
extension Payee: Identified {}
