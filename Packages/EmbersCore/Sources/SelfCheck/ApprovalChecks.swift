import Foundation
import EmbersCore
import EmbersData
import SwiftData

/// Scheduled entries wait to be approved, and uncategorised ones are reported.
///
/// A subscription cancelled in real life used to be spent from the plan on its day regardless,
/// because a scheduled entry turned into an ordinary one the moment its date came. And spending
/// entered without a category left Ready to Assign $48.25 above the accounts with every envelope
/// covered, with nothing on screen saying why.
@MainActor
func approvalChecks(_ check: Checker) {
    let today = Date.budgetDay(year: 2026, month: 10, day: 17)
    let october = YearMonth(year: 2026, month: 10)

    @MainActor func plan(_ context: ModelContext) -> (Account, BudgetCategoryModel) {
        let group = CategoryGroup(name: "Subscriptions")
        let streaming = BudgetCategoryModel(name: "Streaming", group: group)
        let checking = Account(name: "Checking", type: .checking)
        context.insert(group)
        context.insert(streaming)
        context.insert(checking)
        return (checking, streaming)
    }

    @MainActor func compute(_ context: ModelContext, asOf: Date) throws -> BudgetResult {
        BudgetEngine().compute(try BudgetInputBuilder.build(from: context), asOf: asOf, through: october)
    }

    check.suite("Scheduled entries wait to be approved") {
        check.test("everything dated after today is marked, and nothing before") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, streaming) = plan(context)
            let past = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 10, day: 3), amountMinor: -1_000,
                account: checking, category: streaming
            )
            let future = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 10, day: 24), amountMinor: -530,
                account: checking, category: streaming
            )
            context.insert(past)
            context.insert(future)
            try context.save()

            check.expect(try RecurrenceWriter.markScheduled(in: context, asOf: today), 1)
            check.expectTrue(future.awaitsApproval, "the future entry waits")
            check.expectTrue(!past.awaitsApproval, "the past one has happened")
            check.expect(try RecurrenceWriter.markScheduled(in: context, asOf: today), 0, "and only once")
        }

        check.test("a due entry counts for nothing until it is approved") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, streaming) = plan(context)
            let netflix = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 10, day: 24), amountMinor: -350,
                account: checking, category: streaming
            )
            context.insert(netflix)
            try context.save()
            try RecurrenceWriter.markScheduled(in: context, asOf: today)

            // Its day comes.
            let later = Date.budgetDay(year: 2026, month: 10, day: 25)
            let waiting = try compute(context, asOf: later)
            check.expect(waiting.accountBalances[checking.identifier] ?? 0, 0, "the balance is untouched")
            check.expect(waiting.upcoming(for: checking.identifier), -350, "it is still upcoming")
            check.expect(waiting.state(of: streaming.identifier, in: october).activity, 0, "no activity")
            check.expect(try RecurrenceWriter.dueForApproval(in: context, asOf: later).count, 1)

            try RecurrenceWriter.approve(netflix, in: context)
            let approved = try compute(context, asOf: later)
            check.expect(approved.accountBalances[checking.identifier] ?? 0, -350, "now it has happened")
            check.expect(approved.state(of: streaming.identifier, in: october).activity, -350)
            check.expect(try RecurrenceWriter.dueForApproval(in: context, asOf: later).count, 0)
        }

        check.test("approving a repeat schedules the one after it, which waits in turn") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, streaming) = plan(context)
            let netflix = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 8, day: 27), amountMinor: -350,
                account: checking, category: streaming
            )
            netflix.recurrence = .monthly
            context.insert(netflix)
            try context.save()
            try RecurrenceWriter.markScheduled(in: context, asOf: .budgetDay(year: 2026, month: 8, day: 1))

            // Two months pass unopened: only August's is due, because only it exists.
            check.expect(try RecurrenceWriter.dueForApproval(in: context, asOf: today).count, 1)
            try RecurrenceWriter.approve(netflix, in: context)
            check.expectNil(netflix.recurrence, "the approved one is an ordinary entry")

            // September's, the very next date rather than one after today, is due too.
            let due = try RecurrenceWriter.dueForApproval(in: context, asOf: today)
            let september = try check.unwrap(due.first)
            check.expect(due.count, 1)
            check.expect(september.date, .budgetDay(year: 2026, month: 9, day: 27))
            check.expect(september.recurrence, .monthly, "the rule moved with it")
            check.expectTrue(september.awaitsApproval)
        }

        check.test("skipping a repeat moves it on without entering it") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, streaming) = plan(context)
            let netflix = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 10, day: 12), amountMinor: -350,
                account: checking, category: streaming
            )
            netflix.recurrence = .monthly
            netflix.awaitsApproval = true
            context.insert(netflix)
            try context.save()

            try RecurrenceWriter.skip(netflix, in: context)
            check.expect(netflix.date, .budgetDay(year: 2026, month: 11, day: 12))
            check.expect(netflix.recurrence, .monthly)
            check.expectTrue(netflix.awaitsApproval, "still a schedule")
            check.expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 1, "nothing entered")
            check.expect(try compute(context, asOf: today).accountBalances[checking.identifier] ?? 0, 0)
        }

        check.test("skipping something that does not repeat removes it") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, _) = plan(context)
            let once = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 10, day: 12), amountMinor: -2_000, account: checking
            )
            once.awaitsApproval = true
            context.insert(once)
            try context.save()

            try RecurrenceWriter.skip(once, in: context)
            check.expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 0)
        }

        check.test("a repeating transfer is approved on both sides and continues on both") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, _) = plan(context)
            let savings = Account(name: "Savings", type: .savings)
            context.insert(savings)
            let sides = TransferWriter.makeTransfer(
                amountMinor: 50_000, from: checking, to: savings,
                date: .budgetDay(year: 2026, month: 10, day: 20), recurrence: .monthly, in: context
            )
            try context.save()
            try RecurrenceWriter.markScheduled(in: context, asOf: today)
            check.expectTrue(sides.incoming.awaitsApproval, "both sides wait")

            let later = Date.budgetDay(year: 2026, month: 10, day: 21)
            check.expect(try RecurrenceWriter.dueForApproval(in: context, asOf: later).count, 1, "listed once")
            check.expect(try RecurrenceWriter.approveDue(in: context, asOf: later), 1)
            check.expectTrue(!sides.outgoing.awaitsApproval && !sides.incoming.awaitsApproval)

            let result = try compute(context, asOf: later)
            check.expect(result.accountBalances[savings.identifier] ?? 0, 50_000, "the money moved")
            let all = try context.fetch(FetchDescriptor<LedgerTransaction>())
            let november = all.filter { Calendar.gregorianUTC.component(.month, from: $0.date) == 11 }
            check.expect(november.count, 2, "both sides of the next one")
            check.expectTrue(november.allSatisfy(\.awaitsApproval))
        }

        check.test("the launch catch-up leaves a due entry for the person") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, streaming) = plan(context)
            let netflix = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 10, day: 12), amountMinor: -350,
                account: checking, category: streaming
            )
            netflix.recurrence = .monthly
            netflix.awaitsApproval = true
            context.insert(netflix)
            try context.save()

            check.expect(try RecurrenceWriter.advanceDueOccurrences(in: context, asOf: today), 0)
            check.expect(netflix.recurrence, .monthly)
            check.expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 1)
        }

        check.test("reports and reconciling leave out what is not approved") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, streaming) = plan(context)
            let netflix = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 10, day: 12), amountMinor: -350,
                cleared: .cleared, account: checking, category: streaming
            )
            netflix.awaitsApproval = true
            context.insert(netflix)
            try context.save()

            let flows = ReportBuilder.flows(
                try BudgetInputBuilder.build(from: context), from: october, through: october, asOf: today
            )
            check.expect(flows.reduce(0) { $0 + $1.spending }, 0, "no spending reported")
            let reconcile = try ReconcileWriter.plan(
                for: checking, statementBalanceMinor: 0, asOf: today, in: context
            )
            check.expect(reconcile.clearedBalanceMinor, 0, "a statement cannot show it")
        }

        check.test("the flag survives a real file and a reopen") {
            let url = URL.temporaryDirectory.appending(path: "approval-\(UUID().uuidString).store")
            let identifier: UUID
            do {
                let context = ModelContext(try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url))
                let checking = Account(name: "Checking", type: .checking)
                context.insert(checking)
                let rent = LedgerTransaction(date: today, amountMinor: -120_000, account: checking)
                rent.awaitsApproval = true
                context.insert(rent)
                try context.save()
                identifier = rent.identifier
            }
            let reopened = ModelContext(try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url))
            let found = try check.unwrap(
                try reopened.fetch(FetchDescriptor<LedgerTransaction>()).first { $0.identifier == identifier }
            )
            check.expectTrue(found.awaitsApproval)
        }

        check.test("a backup carries it") {
            let source = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, _) = plan(source)
            let waiting = LedgerTransaction(date: today, amountMinor: -350, account: checking)
            waiting.awaitsApproval = true
            source.insert(waiting)
            source.insert(LedgerTransaction(date: today, amountMinor: -100, account: checking))
            try source.save()

            let destination = ModelContext(try EmbersStore.inMemoryContainer())
            try BackupWriter.restore(
                try BackupWriter.decode(try BackupWriter.data(from: source)), into: destination
            )
            let restored = try destination.fetch(FetchDescriptor<LedgerTransaction>())
            check.expect(restored.filter(\.awaitsApproval).map(\.amountMinor), [-350])
        }
    }

    check.suite("Uncategorised entries are reported") {
        check.test("lists spending and income with no category, and nothing else") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, streaming) = plan(context)
            let savings = Account(name: "Savings", type: .savings)
            let apartment = Account(name: "Apartment", type: .otherAsset, onBudget: false)
            context.insert(savings)
            context.insert(apartment)

            let gov = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 10, day: 15), amountMinor: -4_624, account: checking
            )
            let refund = LedgerTransaction(
                date: .budgetDay(year: 2026, month: 10, day: 16), amountMinor: 1_000, account: checking
            )
            for transaction in [
                gov, refund,
                // Categorised.
                LedgerTransaction(date: today, amountMinor: -350, account: checking, category: streaming),
                // Not happened yet, and waiting.
                LedgerTransaction(date: .budgetDay(year: 2026, month: 11, day: 1), amountMinor: -10, account: checking),
                // A tracked account is outside the plan.
                LedgerTransaction(date: today, amountMinor: 500, account: apartment),
            ] { context.insert(transaction) }
            let due = LedgerTransaction(date: today, amountMinor: -20, account: checking)
            due.awaitsApproval = true
            context.insert(due)
            // A move between budget accounts needs no category.
            TransferWriter.makeTransfer(amountMinor: 5_000, from: checking, to: savings, date: today, in: context)
            try context.save()

            let result = try compute(context, asOf: today)
            check.expect(result.uncategorized, [gov.identifier, refund.identifier], "oldest first")
        }

        check.test("they are why Ready to Assign and the accounts disagree") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, streaming) = plan(context)
            let inflowGroup = CategoryGroup(name: "Inflow")
            let inflow = BudgetCategoryModel(name: "Ready to Assign", group: inflowGroup, kind: .inflowReadyToAssign)
            context.insert(inflowGroup)
            context.insert(inflow)
            context.insert(LedgerTransaction(date: today, amountMinor: 100_000, account: checking, category: inflow))
            let gov = LedgerTransaction(date: today, amountMinor: -4_825, account: checking)
            context.insert(gov)
            try context.save()

            let before = try check.unwrap(try compute(context, asOf: today).months[october])
            check.expect(before.readyToAssign - before.onBudgetFunds, 4_825, "the gap is the uncategorised entry")

            gov.category = streaming
            try AssignmentWriter.setAssigned(4_825, category: streaming, month: october, in: context)
            try context.save()
            let after = try check.unwrap(try compute(context, asOf: today).months[october])
            check.expect(after.readyToAssign, after.onBudgetFunds, "categorised and covered, they agree")
            check.expectTrue(try compute(context, asOf: today).uncategorized.isEmpty)
        }
    }
}
