import Foundation
import EmbersCore
import SwiftData

/// Writes the assigned amounts behind the Plan screen.
///
/// **Every change is a row of its own, and rows are only ever added.** A cell's amount is the sum
/// of its rows, which the engine already adds up. Storing the cell's total instead lost money with
/// two devices: each wrote its own new total, one survived, and the destinations of both edits kept
/// what they gained, so Ready to Assign moved by an amount nobody assigned. Two changes are two
/// rows, and both survive.
///
/// The cost is a row per edit rather than per cell — a few hundred a year. They are never folded
/// back together: two devices compacting the same rows would each write their sum, and count them
/// twice.
@MainActor
public enum AssignmentWriter {
    /// Sets what a category has assigned in a month.
    ///
    /// - Parameter shown: What the person saw in the cell when they typed. The change recorded is
    ///   the difference from that, not from what the store holds by the time they save: an edit
    ///   arriving from another device in between would otherwise be quietly undone. Nil uses the
    ///   store's amount, for callers with nothing on screen.
    public static func setAssigned(
        _ amount: MinorUnits,
        shown: MinorUnits? = nil,
        category: BudgetCategoryModel,
        month: YearMonth,
        in context: ModelContext
    ) throws {
        let from = try shown ?? assignedAmount(for: category, month: month, in: context)
        try adjustAssigned(by: amount - from, category: category, month: month, in: context)
    }

    /// Adds to what a category has assigned, for "move money" and covering an overspend.
    public static func adjustAssigned(
        by delta: MinorUnits,
        category: BudgetCategoryModel,
        month: YearMonth,
        in context: ModelContext
    ) throws {
        guard delta != 0 else { return }
        context.insert(CategoryAssignment(month: month, amountMinor: Int(delta), category: category))
        try context.save()
    }

    /// Moves money from one category to another within a month, leaving the month's total untouched.
    public static func move(
        _ amount: MinorUnits,
        from source: BudgetCategoryModel,
        to destination: BudgetCategoryModel,
        month: YearMonth,
        in context: ModelContext
    ) throws {
        try adjustAssigned(by: -amount, category: source, month: month, in: context)
        try adjustAssigned(by: amount, category: destination, month: month, in: context)
    }

    public static func assignedAmount(
        for category: BudgetCategoryModel,
        month: YearMonth,
        in context: ModelContext
    ) throws -> MinorUnits {
        try assignments(for: category, month: month, in: context)
            .reduce(0) { $0 + MinorUnits($1.amountMinor) }
    }

    private static func assignments(
        for category: BudgetCategoryModel,
        month: YearMonth,
        in context: ModelContext
    ) throws -> [CategoryAssignment] {
        let categoryID = category.identifier
        let ordinal = month.ordinal
        return try context.fetch(
            FetchDescriptor<CategoryAssignment>(
                predicate: #Predicate { assignment in
                    assignment.monthOrdinal == ordinal
                        && assignment.category?.identifier == categoryID
                }
            )
        )
    }
}
