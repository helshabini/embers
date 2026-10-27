import Foundation
import EmbersCore
import EmbersData
import SwiftData

/// Both sides of a transfer knowing about one another.
///
/// The importer used to match transfer rows only to count them, then write them as two unrelated
/// entries. Deleting one side left the other behind, and editing one did not move the other — the
/// register stayed balanced only by luck.
@MainActor
func transferPairingChecks(_ check: Checker) {
    let date = Date.budgetDay(year: 2026, month: 3, day: 12)

    @MainActor func twoAccounts(_ context: ModelContext) -> (Account, Account) {
        let checking = Account(name: "Checking", type: .checking)
        let savings = Account(name: "Savings", type: .savings)
        context.insert(checking)
        context.insert(savings)
        return (checking, savings)
    }

    /// Two rows facing each other with no identifier tying them — what the importer used to write.
    @MainActor func writeLooseTransfer(
        _ context: ModelContext, from: Account, to: Account,
        amountMinor: Int, on day: Date
    ) -> (LedgerTransaction, LedgerTransaction) {
        let outgoing = LedgerTransaction(
            date: day, amountMinor: -amountMinor, account: from, transferCounterAccount: to
        )
        let incoming = LedgerTransaction(
            date: day, amountMinor: amountMinor, account: to, transferCounterAccount: from
        )
        context.insert(outgoing)
        context.insert(incoming)
        return (outgoing, incoming)
    }

    check.suite("Repairing transfers that were never tied together") {
        check.test("ties the two sides together") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, savings) = twoAccounts(context)
            let sides = writeLooseTransfer(
                context, from: checking, to: savings, amountMinor: 25_000, on: date
            )
            try context.save()
            check.expectNil(sides.0.transferPairIdentifier, "this is the state being repaired")

            check.expect(try TransferWriter.repairUnpairedTransfers(in: context), 1)
            check.expect(sides.0.transferPairIdentifier, sides.1.transferPairIdentifier)
            check.expectTrue(sides.0.transferPairIdentifier != nil, "and it is a real identifier")
        }

        check.test("either side now deletes both") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, savings) = twoAccounts(context)
            let sides = writeLooseTransfer(
                context, from: checking, to: savings, amountMinor: 25_000, on: date
            )
            try context.save()
            try TransferWriter.repairUnpairedTransfers(in: context)

            // The side that used to be the one that did not work.
            check.expect(try TransactionWriter.delete(sides.1, in: context), 2)
            check.expect(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 0)
        }

        check.test("editing either side moves the other") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, savings) = twoAccounts(context)
            let sides = writeLooseTransfer(
                context, from: checking, to: savings, amountMinor: 25_000, on: date
            )
            try context.save()
            try TransferWriter.repairUnpairedTransfers(in: context)

            sides.1.amountMinor = 40_000
            try TransferWriter.syncCounterpart(of: sides.1, in: context)
            check.expect(sides.0.amountMinor, -40_000, "the other side follows")
        }

        check.test("leaves a one-sided transfer alone rather than inventing a partner") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, savings) = twoAccounts(context)
            let orphan = LedgerTransaction(
                date: date, amountMinor: -25_000, account: checking, transferCounterAccount: savings
            )
            context.insert(orphan)
            try context.save()

            check.expect(try TransferWriter.repairUnpairedTransfers(in: context), 0)
            check.expectNil(orphan.transferPairIdentifier)
        }

        check.test("does not pair two transfers that merely look alike") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, savings) = twoAccounts(context)
            // Two separate transfers the same way on the same day: four rows, two pairs, and no
            // crossing over.
            writeLooseTransfer(context, from: checking, to: savings, amountMinor: 25_000, on: date)
            writeLooseTransfer(context, from: checking, to: savings, amountMinor: 25_000, on: date)
            try context.save()

            check.expect(try TransferWriter.repairUnpairedTransfers(in: context), 2)
            let all = try context.fetch(FetchDescriptor<LedgerTransaction>())
            let identifiers = Set(all.compactMap(\.transferPairIdentifier))
            check.expect(identifiers.count, 2, "two transfers, two identifiers")
            for identifier in identifiers {
                let sides = all.filter { $0.transferPairIdentifier == identifier }
                check.expect(sides.count, 2)
                check.expect(
                    sides.reduce(0) { $0 + $1.amountMinor }, 0,
                    "a pair is one row each way, not two the same way"
                )
            }
        }

        check.test("finds nothing to do the second time") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, savings) = twoAccounts(context)
            writeLooseTransfer(context, from: checking, to: savings, amountMinor: 25_000, on: date)
            try context.save()

            check.expect(try TransferWriter.repairUnpairedTransfers(in: context), 1)
            check.expect(
                try TransferWriter.repairUnpairedTransfers(in: context), 0,
                "a repaired budget is repaired"
            )
        }

        check.test("leaves an ordinary transaction out of it") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (checking, _) = twoAccounts(context)
            let groceries = LedgerTransaction(date: date, amountMinor: -8_000, account: checking)
            context.insert(groceries)
            try context.save()

            check.expect(try TransferWriter.repairUnpairedTransfers(in: context), 0)
            check.expectNil(groceries.transferPairIdentifier)
        }
    }
}

/// What a backup has to carry, checked by writing one and reading it back.
///
/// A backup that quietly drops a field is worse than one that fails: it restores, looks right, and
/// the thing it lost is only missed later. Repeat rules were dropped this way — every scheduled
/// transaction came back as a one-off, and the schedule simply stopped.
@MainActor
func backupFidelityChecks(_ check: Checker) {
    let december = Date.budgetDay(year: 2026, month: 12, day: 8)

    check.suite("A backup keeps what it was given") {
        check.test("a repeating transfer comes back still repeating, and still paired") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let checking = Account(name: "Atlas Checking", type: .checking)
            let apartment = Account(name: "Apartment", type: .otherAsset)
            let group = CategoryGroup(name: "Debt Payments")
            let mortgage = BudgetCategoryModel(name: "Mortgage", group: group)
            context.insert(checking)
            context.insert(apartment)
            context.insert(group)
            context.insert(mortgage)
            TransferWriter.makeTransfer(
                amountMinor: 600_320, from: checking, to: apartment, date: december,
                category: mortgage, recurrence: .everyThreeMonths, in: context
            )
            try context.save()

            let archive = try BackupWriter.archive(from: context)
            let restored = ModelContext(try EmbersStore.inMemoryContainer())
            try BackupWriter.restore(archive, into: restored)

            let all = try restored.fetch(FetchDescriptor<LedgerTransaction>())
            check.expect(all.count, 2, "both sides come back")
            let scheduled = try check.unwrap(all.first { $0.recurrence != nil })
            check.expect(
                scheduled.recurrence, .everyThreeMonths,
                "a backup that loses the rule stops the schedule without saying so"
            )
            check.expect(scheduled.category?.name, "Mortgage")
            check.expect(
                Set(all.compactMap(\.transferPairIdentifier)).count, 1,
                "and the two sides are still tied together"
            )
        }

        check.test("restoring an older backup ties its transfers together") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let checking = Account(name: "Checking", type: .checking)
            let savings = Account(name: "Savings", type: .savings)
            context.insert(checking)
            context.insert(savings)
            let outgoing = LedgerTransaction(
                date: december, amountMinor: -25_000, account: checking,
                transferCounterAccount: savings
            )
            let incoming = LedgerTransaction(
                date: december, amountMinor: 25_000, account: savings,
                transferCounterAccount: checking
            )
            context.insert(outgoing)
            context.insert(incoming)
            try context.save()

            // What a backup taken before pairing existed looks like.
            var archive = try BackupWriter.archive(from: context)
            for index in archive.transactions.indices {
                archive.transactions[index].transferPairIdentifier = nil
            }

            let restored = ModelContext(try EmbersStore.inMemoryContainer())
            try BackupWriter.restore(archive, into: restored)

            let all = try restored.fetch(FetchDescriptor<LedgerTransaction>())
            let identifiers = Set(all.compactMap(\.transferPairIdentifier))
            check.expect(identifiers.count, 1, "restoring mends what the old backup could not carry")
            check.expect(try TransactionWriter.delete(all[0], in: restored), 2)
        }

        check.test("carries the cleared status, the conversion and the flag") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let account = Account(name: "Checking", type: .checking, currencyCode: "EGP")
            context.insert(account)
            let conversion = CurrencyConversion(
                enteredAmount: 300_160_00, enteredCurrencyCode: "EGP", rateToBase: 0.02,
                rateAsOf: december, rateSource: "test", isManualRate: false,
                feePercent: 3, convertedBeforeFee: 600_320, feeAmount: 18_009, baseAmount: 618_329
            )
            let entry = LedgerTransaction(
                date: december, amountMinor: -618_329, memo: "Rent",
                cleared: .reconciled, flag: .red, account: account, conversion: conversion
            )
            context.insert(entry)
            try context.save()

            let restored = ModelContext(try EmbersStore.inMemoryContainer())
            try BackupWriter.restore(try BackupWriter.archive(from: context), into: restored)

            let back = try check.unwrap(
                try restored.fetch(FetchDescriptor<LedgerTransaction>()).first
            )
            check.expect(back.cleared, .reconciled, "reconciled is a statement, not a guess")
            check.expect(back.flag, .red)
            check.expect(back.memo, "Rent")
            check.expect(back.conversion?.enteredCurrencyCode, "EGP")
            check.expect(back.conversion?.feeAmount, 18_009, "the bank's fee is part of the record")
        }
    }
}

/// Which side of a boundary transfer carries the category.
///
/// One category lives between the two rows, on the side inside the budget. On both, the same
/// movement counts once as money arriving and once as money leaving, and they cancel — a withdrawal
/// from a certificate of deposit would reach the budget as nothing at all.
@MainActor
func boundaryCategoryChecks(_ check: Checker) {
    let september = Date.budgetDay(year: 2026, month: 9, day: 30)
    let month = YearMonth(year: 2026, month: 9)

    struct Setup {
        var context: ModelContext
        var savings: Account
        var deposit: Account
        var inflow: BudgetCategoryModel
    }

    @MainActor func setUp() throws -> Setup {
        let context = ModelContext(try EmbersStore.inMemoryContainer())
        let savings = Account(name: "Atlas Savings", type: .savings)
        let deposit = Account(name: "Nile Bank CD", type: .investment)
        context.insert(savings)
        context.insert(deposit)
        let inflow = try AccountWriter.inflowCategory(in: context)
        try context.save()
        return Setup(context: context, savings: savings, deposit: deposit, inflow: inflow)
    }

    @MainActor func readyToAssign(_ context: ModelContext) throws -> MinorUnits {
        BudgetEngine()
            .compute(try BudgetInputBuilder.build(from: context), through: month)
            .readyToAssign(in: month)
    }

    check.suite("A transfer across the edge of the budget") {
        check.test("carries its category on the budget side, whichever way it is made") {
            let s = try setUp()
            // Withdrawn from the deposit, so the deposit is the source — but the money arrives in
            // the budget, and that is the side the category belongs to.
            let sides = TransferWriter.makeTransfer(
                amountMinor: 240_000, from: s.deposit, to: s.savings, date: september,
                category: s.inflow, in: s.context
            )
            try s.context.save()

            check.expectNil(sides.outgoing.category, "the tracked side carries none")
            check.expect(sides.incoming.category?.identifier, s.inflow.identifier)
            check.expect(
                try readyToAssign(s.context), 240_000,
                "money out of a deposit becomes money to assign"
            )
        }

        check.test("a category on both sides would cancel, so the engine ignores the tracked one") {
            let s = try setUp()
            let sides = TransferWriter.makeTransfer(
                amountMinor: 240_000, from: s.deposit, to: s.savings, date: september,
                category: s.inflow, in: s.context
            )
            // What a careless edit from the deposit's own register would have written.
            sides.outgoing.category = s.inflow
            try s.context.save()

            check.expect(
                try readyToAssign(s.context), 240_000,
                "the tracked account is outside the plan, so its category counts for nothing"
            )
        }

        check.test("placing a category reaches the budget side from either row") {
            let s = try setUp()
            let sides = TransferWriter.makeTransfer(
                amountMinor: 240_000, from: s.deposit, to: s.savings, date: september, in: s.context
            )
            try s.context.save()
            check.expect(try readyToAssign(s.context), 240_000, "uncategorised, it still arrives")

            // Opened from the deposit — the side that is not the budget's.
            try TransferWriter.placeCategory(
                s.inflow, onBudgetSideOf: sides.outgoing, in: s.context
            )
            check.expect(sides.incoming.category?.identifier, s.inflow.identifier)
            check.expectNil(sides.outgoing.category)
            check.expect(
                try readyToAssign(s.context), 240_000,
                "naming it changes nothing, which is how it should feel"
            )
        }

        check.test("money leaving the budget is spending from the budget side") {
            let s = try setUp()
            let group = CategoryGroup(name: "Quality of Life Goals")
            let investing = BudgetCategoryModel(name: "Investing", group: group)
            s.context.insert(group)
            s.context.insert(investing)
            s.context.insert(
                LedgerTransaction(
                    date: .budgetDay(year: 2026, month: 9, day: 1), amountMinor: 500_000,
                    account: s.savings, category: s.inflow
                )
            )
            let sides = TransferWriter.makeTransfer(
                amountMinor: 200_000, from: s.savings, to: s.deposit, date: september,
                category: investing, in: s.context
            )
            try s.context.save()

            check.expect(sides.outgoing.category?.identifier, investing.identifier)
            check.expectNil(sides.incoming.category, "the deposit is outside the plan")

            let result = BudgetEngine()
                .compute(try BudgetInputBuilder.build(from: s.context), through: month)
            check.expect(
                result.state(of: investing.identifier, in: month).activity, -200_000,
                "it is spending, and it belongs to the category it came from"
            )
            check.expect(
                result.readyToAssign(in: month), 500_000,
                "spending is not assigning, so what is left to assign has not moved"
            )
        }

        check.test("a move between two budget accounts carries no category at all") {
            let s = try setUp()
            let cash = Account(name: "Cash", type: .cash)
            s.context.insert(cash)
            let sides = TransferWriter.makeTransfer(
                amountMinor: 10_000, from: s.savings, to: cash, date: september,
                category: s.inflow, in: s.context
            )
            try s.context.save()
            try TransferWriter.placeCategory(nil, onBudgetSideOf: sides.outgoing, in: s.context)
            check.expectNil(sides.outgoing.category)
            check.expectNil(sides.incoming.category)
            check.expect(
                try readyToAssign(s.context), 0,
                "moving money inside the budget creates none"
            )
        }
    }
}

/// The launch check: mend what can be mended, report what needs a person.
@MainActor
func budgetAuditChecks(_ check: Checker) {
    let september = Date.budgetDay(year: 2026, month: 9, day: 30)

    @MainActor func setUp() throws -> (ModelContext, Account, Account, BudgetCategoryModel) {
        let context = ModelContext(try EmbersStore.inMemoryContainer())
        let savings = Account(name: "Atlas Savings", type: .savings)
        let deposit = Account(name: "Nile Bank CD", type: .investment)
        context.insert(savings)
        context.insert(deposit)
        let inflow = try AccountWriter.inflowCategory(in: context)
        try context.save()
        return (context, savings, deposit, inflow)
    }

    check.suite("Checking a budget over") {
        check.test("moves a category off the tracked side onto the budget side") {
            let (context, savings, deposit, inflow) = try setUp()
            let sides = TransferWriter.makeTransfer(
                amountMinor: 240_000, from: deposit, to: savings, date: september, in: context
            )
            // Written by a version that put it on whichever row was being edited.
            sides.outgoing.category = inflow
            try context.save()

            let repairs = try BudgetAudit.repair(in: context)
            check.expect(repairs.categoriesMovedToBudgetSide, 1)
            check.expectNil(sides.outgoing.category, "the tracked side is cleared")
            check.expect(sides.incoming.category?.identifier, inflow.identifier)
        }

        check.test("moves an entry dated with an instant onto the local day it was entered") {
            let (context, savings, _, _) = try setUp()
            let dubai = try check.unwrap(TimeZone(identifier: "Asia/Dubai"))
            // The real rows: Snackbox saved at 21:37Z on 30 Sep, which was 01:37 on 1 Oct in Dubai,
            // and one at 09:09Z that was the same day either way.
            let lateNight = LedgerTransaction(
                date: try check.unwrap(ISO8601DateFormatter().date(from: "2026-09-30T21:37:00Z")),
                amountMinor: -790, account: savings
            )
            let morning = LedgerTransaction(
                date: try check.unwrap(ISO8601DateFormatter().date(from: "2026-09-30T09:09:00Z")),
                amountMinor: -100, account: savings
            )
            let fine = LedgerTransaction(date: september, amountMinor: -100, account: savings)
            for row in [lateNight, morning, fine] { context.insert(row) }
            try context.save()

            check.expect(try BudgetAudit.repair(in: context, timeZone: dubai).datesMovedToBudgetDay, 2)
            check.expect(lateNight.date, .budgetDay(year: 2026, month: 10, day: 1), "October, locally")
            check.expect(morning.date, september)
            check.expect(fine.date, september, "a budget day is left alone")
            check.expect(
                try BudgetAudit.repair(in: context, timeZone: dubai).datesMovedToBudgetDay, 0,
                "and the second run finds nothing"
            )
        }

        check.test("clears a category on a tracked account's own entry") {
            let (context, _, deposit, inflow) = try setUp()
            let interest = LedgerTransaction(
                date: september, amountMinor: 5_000, account: deposit, category: inflow
            )
            context.insert(interest)
            try context.save()

            check.expect(try BudgetAudit.repair(in: context).strayCategoriesCleared, 1)
            check.expectNil(interest.category, "a tracked account is outside the plan")
        }

        check.test("reports a boundary transfer with no category rather than guessing") {
            let (context, savings, deposit, _) = try setUp()
            let sides = TransferWriter.makeTransfer(
                amountMinor: 240_000, from: deposit, to: savings, date: september, in: context
            )
            try context.save()
            try BudgetAudit.repair(in: context)

            let findings = try BudgetAudit.findings(in: context)
            check.expect(findings.uncategorisedBoundaryTransfers.count, 1)
            check.expect(
                findings.uncategorisedBoundaryTransfers.first, sides.incoming.identifier,
                "and points at the side the answer belongs on"
            )
            check.expectTrue(!findings.isClear)
        }

        check.test("says nothing once the category is given") {
            let (context, savings, deposit, inflow) = try setUp()
            let sides = TransferWriter.makeTransfer(
                amountMinor: 240_000, from: deposit, to: savings, date: september, in: context
            )
            try context.save()
            try TransferWriter.placeCategory(inflow, onBudgetSideOf: sides.outgoing, in: context)

            check.expectTrue(
                try BudgetAudit.findings(in: context).isClear,
                "answered is answered"
            )
        }

        check.test("leaves a move between two budget accounts alone") {
            let (context, savings, _, _) = try setUp()
            let cash = Account(name: "Cash", type: .cash)
            context.insert(cash)
            TransferWriter.makeTransfer(
                amountMinor: 10_000, from: savings, to: cash, date: september, in: context
            )
            try context.save()
            try BudgetAudit.repair(in: context)

            check.expectTrue(
                try BudgetAudit.findings(in: context).isClear,
                "money moving inside the budget needs no envelope"
            )
        }

        check.test("running it twice changes nothing the second time") {
            let (context, savings, deposit, inflow) = try setUp()
            let sides = TransferWriter.makeTransfer(
                amountMinor: 240_000, from: deposit, to: savings, date: september, in: context
            )
            sides.outgoing.category = inflow
            try context.save()

            try BudgetAudit.repair(in: context)
            check.expectTrue(
                !(try BudgetAudit.repair(in: context).didChangeAnything),
                "a mended budget stays mended"
            )
        }
    }
}
