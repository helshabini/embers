import Foundation
import EmbersCore
import EmbersData
import SwiftData

@MainActor
func assignmentChecks(_ check: Checker) {
    let january = YearMonth(year: 2026, month: 1)

    /// A store with two categories and enough income to assign.
    func makeStore() throws -> (ModelContext, BudgetCategoryModel, BudgetCategoryModel, Account) {
        let context = ModelContext(try EmbersStore.inMemoryContainer())
        let group = CategoryGroup(name: "Immediate Obligations")
        let groceries = BudgetCategoryModel(name: "Groceries", group: group, order: 0)
        let dining = BudgetCategoryModel(name: "Dining Out", group: group, order: 1)
        let inflowGroup = CategoryGroup(name: "Inflow")
        let inflow = BudgetCategoryModel(
            name: "Ready to Assign", group: inflowGroup, kind: .inflowReadyToAssign
        )
        let account = Account(name: "Cash", type: .cash)
        context.insert(group)
        context.insert(inflowGroup)
        context.insert(groceries)
        context.insert(dining)
        context.insert(inflow)
        context.insert(account)
        context.insert(
            LedgerTransaction(
                date: .budgetDay(year: 2026, month: 1, day: 2),
                amountMinor: 100_000,
                account: account,
                category: inflow
            )
        )
        try context.save()
        return (context, groceries, dining, account)
    }

    check.suite("Assigning money") {
        check.test("stores an assignment and reads it back") {
            let (context, groceries, _, _) = try makeStore()
            try AssignmentWriter.setAssigned(30_000, category: groceries, month: january, in: context)
            check.expect(try AssignmentWriter.assignedAmount(for: groceries, month: january, in: context), 30_000)
            check.expect(try context.fetchCount(FetchDescriptor<CategoryAssignment>()), 1)
        }

        // A change, not a new total: setting again adds the difference as a row of its own.
        check.test("setting again records the difference") {
            let (context, groceries, _, _) = try makeStore()
            try AssignmentWriter.setAssigned(30_000, category: groceries, month: january, in: context)
            try AssignmentWriter.setAssigned(45_000, category: groceries, month: january, in: context)
            let rows = try context.fetch(FetchDescriptor<CategoryAssignment>())
            check.expect(rows.map(\.amountMinor).sorted(), [15_000, 30_000])
            check.expect(try AssignmentWriter.assignedAmount(for: groceries, month: january, in: context), 45_000)
        }

        check.test("setting to zero leaves nothing assigned, and removes no row") {
            let (context, groceries, _, _) = try makeStore()
            try AssignmentWriter.setAssigned(30_000, category: groceries, month: january, in: context)
            try AssignmentWriter.setAssigned(0, category: groceries, month: january, in: context)
            check.expect(try context.fetchCount(FetchDescriptor<CategoryAssignment>()), 2)
            check.expect(try AssignmentWriter.assignedAmount(for: groceries, month: january, in: context), 0)
        }

        check.test("setting what is already there writes nothing") {
            let (context, groceries, _, _) = try makeStore()
            try AssignmentWriter.setAssigned(30_000, category: groceries, month: january, in: context)
            try AssignmentWriter.setAssigned(30_000, category: groceries, month: january, in: context)
            check.expect(try context.fetchCount(FetchDescriptor<CategoryAssignment>()), 1)
        }

        check.test("rows from an import add up, and a setting changes the sum") {
            let (context, groceries, _, _) = try makeStore()
            context.insert(CategoryAssignment(month: january, amountMinor: 10_000, category: groceries))
            context.insert(CategoryAssignment(month: january, amountMinor: 5_000, category: groceries))
            try context.save()
            check.expect(try AssignmentWriter.assignedAmount(for: groceries, month: january, in: context), 15_000)

            try AssignmentWriter.setAssigned(20_000, category: groceries, month: january, in: context)
            check.expect(try AssignmentWriter.assignedAmount(for: groceries, month: january, in: context), 20_000)
        }

        check.test("adjusting adds to what is already there") {
            let (context, groceries, _, _) = try makeStore()
            try AssignmentWriter.setAssigned(30_000, category: groceries, month: january, in: context)
            try AssignmentWriter.adjustAssigned(by: -10_000, category: groceries, month: january, in: context)
            check.expect(try AssignmentWriter.assignedAmount(for: groceries, month: january, in: context), 20_000)
        }

        check.test("moving money leaves the month's total assigned unchanged") {
            let (context, groceries, dining, _) = try makeStore()
            try AssignmentWriter.setAssigned(30_000, category: groceries, month: january, in: context)
            try AssignmentWriter.setAssigned(10_000, category: dining, month: january, in: context)

            let before = try BudgetInputBuilder.build(from: context)
            let readyBefore = BudgetEngine().compute(before, through: january).readyToAssign(in: january)

            try AssignmentWriter.move(5_000, from: groceries, to: dining, month: january, in: context)
            check.expect(try AssignmentWriter.assignedAmount(for: groceries, month: january, in: context), 25_000)
            check.expect(try AssignmentWriter.assignedAmount(for: dining, month: january, in: context), 15_000)

            let after = try BudgetInputBuilder.build(from: context)
            let readyAfter = BudgetEngine().compute(after, through: january).readyToAssign(in: january)
            check.expect(readyAfter, readyBefore, "moving money does not create or destroy any")
        }

        check.test("assigning reduces Ready to Assign by the same amount") {
            let (context, groceries, _, _) = try makeStore()
            let engine = BudgetEngine()

            let before = engine.compute(try BudgetInputBuilder.build(from: context), through: january)
            check.expect(before.readyToAssign(in: january), 100_000)

            try AssignmentWriter.setAssigned(30_000, category: groceries, month: january, in: context)
            let after = engine.compute(try BudgetInputBuilder.build(from: context), through: january)
            check.expect(after.readyToAssign(in: january), 70_000)
            check.expect(after.state(of: groceries.identifier, in: january).available, 30_000)
        }

        check.test("keeps months apart") {
            let (context, groceries, _, _) = try makeStore()
            try AssignmentWriter.setAssigned(30_000, category: groceries, month: january, in: context)
            try AssignmentWriter.setAssigned(12_000, category: groceries, month: january.next, in: context)
            check.expect(try AssignmentWriter.assignedAmount(for: groceries, month: january, in: context), 30_000)
            check.expect(try AssignmentWriter.assignedAmount(for: groceries, month: january.next, in: context), 12_000)
            check.expect(try context.fetchCount(FetchDescriptor<CategoryAssignment>()), 2)
        }
    }

    // Each device works from what it saw, then the other's rows arrive. Both sets of rows sit in one
    // store here, exactly as after syncing: no total is overwritten, so nothing is lost.
    check.suite("Assigning on two devices at once") {
        func ready(_ context: ModelContext) throws -> MinorUnits {
            BudgetEngine().compute(try BudgetInputBuilder.build(from: context), through: january)
                .readyToAssign(in: january)
        }

        check.test("moving money out of one category on both leaves Ready to Assign where it was") {
            let (context, groceries, dining, _) = try makeStore()
            let fun = BudgetCategoryModel(name: "Fun Money", group: groceries.group, order: 2)
            context.insert(fun)
            try AssignmentWriter.setAssigned(50_000, category: groceries, month: january, in: context)
            let before = try ready(context)

            // The phone moves 5,000 to Dining Out; the iPad, not yet hearing of it, 3,000 to Fun.
            try AssignmentWriter.setAssigned(45_000, shown: 50_000, category: groceries, month: january, in: context)
            try AssignmentWriter.setAssigned(5_000, shown: 0, category: dining, month: january, in: context)
            try AssignmentWriter.setAssigned(47_000, shown: 50_000, category: groceries, month: january, in: context)
            try AssignmentWriter.setAssigned(3_000, shown: 0, category: fun, month: january, in: context)

            check.expect(try ready(context), before, "money was only moved, on both")
            check.expect(try AssignmentWriter.assignedAmount(for: groceries, month: january, in: context), 42_000)
        }

        check.test("an edit that arrives while typing is not undone") {
            let (context, groceries, _, _) = try makeStore()
            try AssignmentWriter.setAssigned(50_000, category: groceries, month: january, in: context)
            // The editor shows 500. Meanwhile the other device covers an overspend with 100.
            try AssignmentWriter.adjustAssigned(by: 10_000, category: groceries, month: january, in: context)
            // The person here takes 50 off what they saw.
            try AssignmentWriter.setAssigned(45_000, shown: 50_000, category: groceries, month: january, in: context)
            check.expect(try AssignmentWriter.assignedAmount(for: groceries, month: january, in: context), 55_000)
        }

        check.test("a month funded and emptied again does not stop a category being deleted") {
            let (context, groceries, _, _) = try makeStore()
            try AssignmentWriter.setAssigned(30_000, category: groceries, month: january, in: context)
            try AssignmentWriter.setAssigned(0, category: groceries, month: january, in: context)
            check.expectNil(try CategoryWriter.deletionRefusal(for: groceries, in: context))
        }
    }
}
