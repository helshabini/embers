import Foundation
import EmbersCore
import EmbersData
import SwiftData

/// What two devices made for themselves before they heard from each other, folded into one.
///
/// CloudKit itself cannot run here, so each check builds the store as it looks once both devices'
/// rows have arrived: everything written twice, side by side. On disk, since merging deletes, and
/// what a delete cascades over is exactly what an in-memory store has got wrong before.
@MainActor
func syncMergeChecks(_ check: Checker) {
    let october = YearMonth(year: 2026, month: 10)
    let firstOfOctober = Date.budgetDay(year: 2026, month: 10, day: 1)

    func onDisk() throws -> ModelContext {
        let url = URL.temporaryDirectory.appending(path: "sync-merge-\(UUID().uuidString).store")
        return ModelContext(try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url))
    }

    /// Identifiers that put the second device's copy first, or last, among the duplicates.
    let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!

    func totalAssigned(in context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<CategoryAssignment>()).reduce(0) { $0 + $1.amountMinor }
    }

    // CloudKit refuses the whole store over one model that breaks its rules, and only when the
    // container opens with syncing on — which no headless check or UI test does. The docs said every
    // relationship had an inverse; two did not, and the first launch with syncing stuck on its splash.
    check.suite("The schema CloudKit will accept") {
        check.test("every relationship has an inverse") {
            let missing = EmbersStore.schema.entities.flatMap { entity in
                entity.relationships.filter { $0.inverseName == nil }.map { "\(entity.name).\($0.name)" }
            }
            check.expect(missing, [], "relationships without an inverse")
        }

        check.test("no attribute is unique") {
            let unique = EmbersStore.schema.entities.flatMap { entity in
                entity.attributes.filter(\.isUnique).map { "\(entity.name).\($0.name)" }
            }
            check.expect(unique, [])
        }
    }

    check.suite("Merging what two devices made") {
        check.test("the oldest settings are the plan's") {
            let context = try onDisk()
            let phone = PlanSettings(baseCurrencyCode: "AED", createdAt: .budgetDay(year: 2025, month: 1, day: 1))
            let iPad = PlanSettings()
            context.insert(phone)
            context.insert(iPad)
            try context.save()

            check.expect(try SyncMerge.mergeDuplicates(in: context).settingsRemoved, 1)
            check.expect(try context.planSettings().baseCurrencyCode, "AED")
        }

        // Both orders, so the history moves to the lower identifier rather than to whichever row
        // happens to be the "real" one — two devices must agree without knowing which that is.
        for (label, seededIdentifier) in [("lower", low), ("higher", high)] {
            check.test("a starter plan seeded twice folds into one, the seeded copy \(label)") {
                let context = try onDisk()
                try CategoryWriter.seedStarterPlan(in: context)
                let groups = try context.fetch(FetchDescriptor<CategoryGroup>())
                let real = try check.unwrap(groups.first { $0.name == "Immediate Obligations" })
                let rent = try check.unwrap(real.categories?.first { $0.name == "Rent" })
                let checking = Account(name: "Checking", type: .checking)
                context.insert(checking)
                context.insert(LedgerTransaction(
                    date: firstOfOctober, amountMinor: -120_000, account: checking, category: rent
                ))
                try AssignmentWriter.setAssigned(120_000, category: rent, month: october, in: context)

                // The second device's seed, arriving afterwards.
                let seeded = CategoryGroup(identifier: seededIdentifier, name: "Immediate Obligations")
                context.insert(seeded)
                for (order, name) in ["Rent", "Electricity"].enumerated() {
                    context.insert(BudgetCategoryModel(name: name, group: seeded, order: order))
                }
                try context.save()

                try SyncMerge.mergeDuplicates(in: context)
                try SyncMerge.mergeDuplicates(in: context)

                let after = try context.fetch(FetchDescriptor<CategoryGroup>())
                    .filter { $0.name == "Immediate Obligations" }
                check.expect(after.count, 2, "the emptied one is kept, never deleted")
                check.expect(after.filter { !$0.hidden }.count, 1, "and only one is on the plan")
                let survivor = try check.unwrap(after.first { !$0.hidden })
                check.expect(survivor.identifier.uuidString, min(real.identifier.uuidString, seededIdentifier.uuidString))
                check.expectTrue(!survivor.hidden, "the group stays on the plan")
                let rents = (survivor.categories ?? []).filter { $0.name == "Rent" && !$0.hidden }
                check.expect(rents.count, 1, "one Rent on the plan")
                check.expect(rents.first?.transactions?.count, 1, "carrying its transaction")
                check.expect(try totalAssigned(in: context), 120_000, "and nothing assigned has moved")
            }
        }

        check.test("an emptied group is hidden, and never deleted") {
            let context = try onDisk()
            let first = CategoryGroup(identifier: low, name: "Bills")
            let second = CategoryGroup(identifier: high, name: "Bills")
            context.insert(first)
            context.insert(second)
            context.insert(BudgetCategoryModel(name: "Water", group: second))
            try context.save()

            let firstRun = try SyncMerge.mergeDuplicates(in: context)
            check.expect(firstRun.groupsFolded, 1)
            check.expectTrue(second.hidden, "hidden")
            // Runs follow every import, seconds apart. A device yet to hear of the move would
            // cascade a deletion over the categories it still holds there.
            check.expect(try SyncMerge.mergeDuplicates(in: context), SyncMerge.Merges(), "a later run finds nothing to do")
            check.expect(try context.fetchCount(FetchDescriptor<CategoryGroup>()), 2, "nothing deleted")
            check.expect(try context.fetchCount(FetchDescriptor<BudgetCategoryModel>()), 1, "Water survives")
        }

        // The Mac that cost its iPhone 5,900 categories: its own starter plan, seeded while it wrongly
        // believed it had no iCloud, met the real plan arriving a piece at a time.
        check.test("a real category that arrives before its history is hidden, not deleted, and gets it later") {
            let context = try onDisk()
            let seededGroup = CategoryGroup(identifier: low, name: "True Expenses")
            context.insert(seededGroup)
            let seeded = BudgetCategoryModel(identifier: low, name: "Medical", group: seededGroup)
            context.insert(seeded)
            // The real group and category have arrived; their transactions have not.
            let realGroup = CategoryGroup(identifier: high, name: "True Expenses")
            context.insert(realGroup)
            let real = BudgetCategoryModel(identifier: high, name: "Medical", group: realGroup)
            context.insert(real)
            try context.save()

            for _ in 0..<3 { try SyncMerge.mergeDuplicates(in: context) }
            check.expect(try context.fetchCount(FetchDescriptor<CategoryGroup>()), 2, "no group deleted")
            check.expect(try context.fetchCount(FetchDescriptor<BudgetCategoryModel>()), 2, "no category deleted")
            check.expectTrue(real.hidden, "the duplicate is hidden")

            // Its history arrives, still pointing at it.
            let checking = Account(name: "Checking", type: .checking)
            context.insert(checking)
            context.insert(LedgerTransaction(date: firstOfOctober, amountMinor: -9_000, account: checking, category: real))
            try context.save()
            try SyncMerge.mergeDuplicates(in: context)
            let entries = try context.fetch(FetchDescriptor<LedgerTransaction>())
            check.expectTrue(entries.allSatisfy { $0.category?.identifier == low }, "the entry keeps a category")
        }

        // A Mac downloading from scratch after the iPhone had restored a backup received 44 categories
        // twice under one identifier: the restored copy, and a stale one iCloud still held with no
        // group and the same assignment rows again. Its budget engine stopped at every launch.
        check.test("a category held twice under one identifier is read once, then folded") {
            let context = try onDisk()
            let group = CategoryGroup(name: "Rainy Day Funds")
            let restored = BudgetCategoryModel(identifier: low, name: "Savings", group: group)
            let stale = BudgetCategoryModel(identifier: low, name: "Savings")
            let checking = Account(name: "Checking", type: .checking)
            for model in [group, restored, stale, checking] as [any PersistentModel] { context.insert(model) }
            context.insert(LedgerTransaction(date: firstOfOctober, amountMinor: -10_000, account: checking, category: restored))
            context.insert(CategoryAssignment(month: october, amountMinor: 100_000, category: restored))
            context.insert(CategoryAssignment(month: october.next, amountMinor: 20_000, category: restored))
            // The same October row again, and one the restored copy does not have.
            context.insert(CategoryAssignment(month: october, amountMinor: 100_000, category: stale))
            context.insert(CategoryAssignment(month: october.adding(months: 2), amountMinor: 5_000, category: stale))
            try context.save()

            // Before any merge: no stop on the repeated identifier, and the stale copy's rows are not
            // the same money counted twice.
            let input = try BudgetInputBuilder.build(from: context)
            check.expect(input.categories.filter { $0.id == low }.count, 1, "read once")
            check.expect(input.assignments.reduce(0) { $0 + $1.amount }, 120_000, "only the copy in its group counts")
            _ = BudgetEngine().compute(input, through: october.adding(months: 2))

            let merges = try SyncMerge.mergeDuplicates(in: context)
            check.expect(merges.duplicateAssignmentsRemoved, 1, "the October row twice is one row")
            check.expect(merges.categoriesFolded, 1)
            check.expectTrue(stale.hidden, "the stale copy is hidden, not deleted")
            check.expect(try context.fetchCount(FetchDescriptor<BudgetCategoryModel>()), 2)
            check.expect(restored.assignments?.count, 3, "the row it lacked moved across")
            check.expect(try totalAssigned(in: context), 125_000)
            let after = try BudgetInputBuilder.build(from: context)
            check.expect(after.assignments.reduce(0) { $0 + $1.amount }, 125_000, "and is counted once it has")
            check.expect(try SyncMerge.mergeDuplicates(in: context), SyncMerge.Merges(), "a later run finds nothing to do")
        }

        check.test("the engine takes one identifier twice without stopping") {
            let twice = [
                BudgetCategory(id: low, name: "Savings", groupName: "Rainy Day Funds", kind: .normal),
                BudgetCategory(id: low, name: "Savings", groupName: "", kind: .normal),
            ]
            _ = BudgetEngine().compute(BudgetInput(accounts: [], categories: twice, entries: [], assignments: []))
            check.expectTrue(true)
        }

        check.test("two categories funded in the same month add together") {
            let context = try onDisk()
            let group = CategoryGroup(name: "Bills")
            let first = BudgetCategoryModel(identifier: low, name: "Water", group: group)
            let second = BudgetCategoryModel(identifier: high, name: "water", group: group)
            for model in [group, first, second] as [any PersistentModel] { context.insert(model) }
            try AssignmentWriter.setAssigned(3_000, category: first, month: october, in: context)
            try AssignmentWriter.setAssigned(2_000, category: second, month: october, in: context)

            try SyncMerge.mergeDuplicates(in: context)
            check.expect(try AssignmentWriter.assignedAmount(for: first, month: october, in: context), 5_000)
            check.expect(try totalAssigned(in: context), 5_000, "Ready to Assign does not move")
        }

        check.test("a card's second payment category is folded, and card sync does not bring it back") {
            let context = try onDisk()
            let card = Account(name: "Visa", type: .creditCard)
            context.insert(card)
            try CategoryWriter.syncCreditCardCategories(in: context)
            let original = try check.unwrap(
                try context.fetch(FetchDescriptor<BudgetCategoryModel>()).first { $0.linkedAccount != nil }
            )
            let group = try check.unwrap(original.group)
            let other = BudgetCategoryModel(
                identifier: original.identifier.uuidString < high.uuidString ? high : low,
                name: "Visa", group: group, kind: .creditCardPayment, linkedAccount: card
            )
            context.insert(other)
            try AssignmentWriter.setAssigned(10_000, category: other, month: october, in: context)

            try BudgetAudit.repair(in: context)
            try BudgetAudit.repair(in: context)
            let payments = try context.fetch(FetchDescriptor<BudgetCategoryModel>())
                .filter { $0.kind == .creditCardPayment && !$0.hidden }
            check.expect(payments.count, 1, "one on the plan; the emptied one is hidden, never deleted")
            check.expect(try totalAssigned(in: context), 10_000)
        }

        check.test("a repeat rolled forward on two devices leaves one next occurrence") {
            let context = try onDisk()
            let checking = Account(name: "Checking", type: .checking)
            context.insert(checking)
            let rent = LedgerTransaction(date: firstOfOctober, amountMinor: -120_000, account: checking)
            context.insert(rent)
            rent.recurrence = .monthly
            try context.save()
            try RecurrenceWriter.advanceDueOccurrences(
                in: context, asOf: .budgetDay(year: 2026, month: 10, day: 2)
            )
            // The other device's copy of the same step.
            let copy = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 11, day: 1), amountMinor: -120_000, account: checking
            )
            copy.recurrence = .monthly
            copy.awaitsApproval = true
            copy.occurrenceOf = rent.identifier
            context.insert(copy)
            try context.save()

            check.expect(try SyncMerge.mergeDuplicates(in: context).occurrencesRemoved, 1)
            check.expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 2, "rent and one next")
        }

        check.test("a repeating transfer rolled forward twice loses a whole pair, not a side of each") {
            let context = try onDisk()
            let checking = Account(name: "Checking", type: .checking)
            let savings = Account(name: "Savings", type: .savings)
            context.insert(checking)
            context.insert(savings)
            let sides = TransferWriter.makeTransfer(
                amountMinor: 50_000, from: checking, to: savings, date: firstOfOctober, in: context
            )
            // Each device's pair, with identifiers that order the two sides oppositely: choosing a
            // survivor per side would keep the outgoing half of one pair and the incoming of the other.
            func id(_ prefix: String) -> UUID { UUID(uuidString: prefix + "-0000-0000-0000-000000000001")! }
            for (pairIdentifier, outgoing, incoming) in [
                (low, id("FFFFFFFF"), id("11111111")), (high, id("22222222"), id("EEEEEEEE")),
            ] {
                let out = LedgerTransaction(
                    identifier: outgoing, date: .budgetDay(year: 2026, month: 11, day: 1),
                    amountMinor: -50_000, account: checking, transferCounterAccount: savings
                )
                let into = LedgerTransaction(
                    identifier: incoming, date: out.date,
                    amountMinor: 50_000, account: savings, transferCounterAccount: checking
                )
                for (row, source) in [(out, sides.outgoing), (into, sides.incoming)] {
                    row.transferPairIdentifier = pairIdentifier
                    row.awaitsApproval = true
                    row.occurrenceOf = source.identifier
                    context.insert(row)
                }
            }
            try context.save()

            check.expect(try SyncMerge.mergeDuplicates(in: context).occurrencesRemoved, 2)
            let next = try context.fetch(FetchDescriptor<LedgerTransaction>())
                .filter { $0.occurrenceOf != nil }
            check.expect(next.count, 2, "one pair")
            check.expect(Set(next.map(\.transferPairIdentifier)), [low], "both sides of the same pair")
        }

        check.test("an approved occurrence stays, and its waiting twin goes") {
            let context = try onDisk()
            let checking = Account(name: "Checking", type: .checking)
            context.insert(checking)
            let source = UUID()
            for (identifier, waits) in [(low, true), (high, false)] {
                let row = LedgerTransaction(
                    identifier: identifier, date: firstOfOctober, amountMinor: -9_900, account: checking
                )
                row.awaitsApproval = waits
                row.occurrenceOf = source
                context.insert(row)
            }
            try context.save()

            try SyncMerge.mergeDuplicates(in: context)
            let left = try context.fetch(FetchDescriptor<LedgerTransaction>())
            check.expect(left.map(\.identifier), [high], "the lower one waited, so it went")
        }

        check.test("two approved occurrences are both left for the person") {
            let context = try onDisk()
            let checking = Account(name: "Checking", type: .checking)
            context.insert(checking)
            let source = UUID()
            for _ in 0..<2 {
                let row = LedgerTransaction(date: firstOfOctober, amountMinor: -9_900, account: checking)
                row.occurrenceOf = source
                context.insert(row)
            }
            try context.save()

            check.expect(try SyncMerge.mergeDuplicates(in: context).occurrencesRemoved, 0)
        }

        check.test("a payee met on two devices folds into one, keeping its entries") {
            let context = try onDisk()
            let checking = Account(name: "Checking", type: .checking)
            let phone = Payee(identifier: high, name: "Carreta Market", lastUsedAt: .budgetDay(year: 2026, month: 10, day: 5))
            let iPad = Payee(identifier: low, name: "carreta market ", lastUsedAt: .budgetDay(year: 2026, month: 10, day: 3))
            for model in [checking, phone, iPad] as [any PersistentModel] { context.insert(model) }
            for payee in [phone, iPad] {
                context.insert(LedgerTransaction(
                    date: firstOfOctober, amountMinor: -5_000, account: checking, payee: payee
                ))
            }
            try context.save()

            check.expect(try SyncMerge.mergeDuplicates(in: context).payeesFolded, 1)
            check.expect(iPad.transactions?.count, 2, "both entries on the lower one")
            check.expect(iPad.lastUsedAt, .budgetDay(year: 2026, month: 10, day: 5), "used as lately as either")
            check.expect(try SyncMerge.mergeDuplicates(in: context), SyncMerge.Merges(), "a later run finds nothing to do")
            check.expect(try context.fetchCount(FetchDescriptor<Payee>()), 2, "the emptied one is kept, never deleted")
            let offered = PayeeMemory.suggestions(matching: "carre", among: try context.fetch(FetchDescriptor<Payee>()))
            check.expect(offered.map(\.identifier), [low], "and only the one kept is offered")
            let entries = try context.fetch(FetchDescriptor<LedgerTransaction>())
            check.expectTrue(entries.allSatisfy { $0.payee?.identifier == low }, "no entry lost its payee")
        }

        check.test("one reconciliation made on two devices adjusts the balance once") {
            let context = try onDisk()
            let checking = Account(name: "Checking", type: .checking)
            context.insert(checking)
            let deposit = LedgerTransaction(date: firstOfOctober, amountMinor: 100_000, account: checking)
            deposit.cleared = .cleared
            context.insert(deposit)
            try context.save()
            let asOf = Date.budgetDay(year: 2026, month: 10, day: 2)

            let adjustment = try check.unwrap(try ReconcileWriter.reconcile(
                checking, statementBalanceMinor: 98_000, asOf: asOf, in: context
            ))
            // The other device worked from the same state, so wrote the same adjustment.
            let twin = LedgerTransaction(
                date: adjustment.date, amountMinor: adjustment.amountMinor, cleared: .reconciled,
                account: checking, payee: adjustment.payee, category: adjustment.category
            )
            twin.reconciliationKey = adjustment.reconciliationKey
            context.insert(twin)
            try context.save()

            check.expect(try SyncMerge.mergeDuplicates(in: context).adjustmentsRemoved, 1)
            let balance = try context.fetch(FetchDescriptor<LedgerTransaction>()).reduce(0) { $0 + $1.amountMinor }
            check.expect(balance, 98_000, "the statement's balance, not adjusted twice")
        }

        check.test("two reconciliations on one day are both kept") {
            let context = try onDisk()
            let checking = Account(name: "Checking", type: .checking)
            context.insert(checking)
            let deposit = LedgerTransaction(date: firstOfOctober, amountMinor: 100_000, account: checking)
            deposit.cleared = .cleared
            context.insert(deposit)
            try context.save()
            let asOf = Date.budgetDay(year: 2026, month: 10, day: 2)

            // The same statement figure both times, but a fee cleared in between: the second
            // adjustment is real, and only the cleared balance it started from tells it apart.
            try ReconcileWriter.reconcile(checking, statementBalanceMinor: 98_000, asOf: asOf, in: context)
            let fee = LedgerTransaction(date: asOf, amountMinor: -1_000, account: checking)
            fee.cleared = .cleared
            context.insert(fee)
            try context.save()
            try ReconcileWriter.reconcile(checking, statementBalanceMinor: 98_000, asOf: asOf, in: context)

            check.expect(try SyncMerge.mergeDuplicates(in: context).adjustmentsRemoved, 0)
            let balance = try context.fetch(FetchDescriptor<LedgerTransaction>()).reduce(0) { $0 + $1.amountMinor }
            check.expect(balance, 98_000)
        }

        check.test("Start Fresh still clears the plan, one object at a time") {
            let context = try onDisk()
            try CategoryWriter.seedStarterPlan(in: context)
            let checking = Account(name: "Checking", type: .checking)
            context.insert(checking)
            context.insert(LedgerTransaction(date: firstOfOctober, amountMinor: -100, account: checking))
            try context.save()

            try ImportWriter.deleteAllPlanData(in: context)
            check.expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 0)
            check.expect(try context.fetchCount(FetchDescriptor<BudgetCategoryModel>()), 0)
            check.expect(try context.fetchCount(FetchDescriptor<CategoryGroup>()), 0)
            check.expect(try context.fetchCount(FetchDescriptor<Account>()), 0)
        }
    }
}
