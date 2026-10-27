import EmbersCore
import EmbersData
import Foundation
import Observation
import SwiftData

/// A transaction being entered or edited: everything the editor holds, and the rules for turning it
/// into rows.
///
/// The phone's editor and the Mac's are different screens over this one draft. What lives here is
/// what must not differ between them — above all which side of a transfer carries the category,
/// and when a transfer needs one at all (docs/transfers/budget-boundary.md). The arithmetic of the
/// amount itself is `AmountEntry`, a value type checked without a screen.
@MainActor
@Observable
final class TransactionDraft {
    let existing: LedgerTransaction?
    private let initialAccount: Account?

    var account: Account?
    var transferDestination: Account?
    var isTransfer = false
    var entry: AmountEntry?
    var payeeName = ""
    var category: BudgetCategoryModel?
    var date = Date.todayAsBudgetDay()
    var memo = ""
    var cleared: ClearedStatus = .uncleared
    var recurrence: Recurrence?
    var manualRateText = "" {
        didSet { entry?.manualRate = Double(manualRateText) }
    }
    var hasChosenCategory = false
    /// Set once the currency has been named by hand. Until then the entry currency follows the
    /// account, because money spent from an EGP account is almost always spent in EGP.
    var hasChosenCurrency = false
    /// Set once the cleared switch has been touched, so changing account stops guessing for them.
    var hasChosenCleared = false
    private(set) var isPrepared = false
    /// Set once the row is deleted, so nothing on the way out reads it again.
    private(set) var hasDeleted = false

    init(account: Account?, existing: LedgerTransaction?) {
        self.initialAccount = account
        self.existing = existing
    }

    var title: String {
        if existing == nil {
            return isTransfer ? String(localized: "New Transfer") : String(localized: "New Transaction")
        }
        return isTransfer ? String(localized: "Edit Transfer") : String(localized: "Edit Transaction")
    }

    // MARK: - Choosing

    func choose(account chosen: Account, planFeePercent: Double) {
        account = chosen
        entry?.accountCurrency = chosen.currency
        entry?.feePercent = Decimal(chosen.fxFeePercentOverride ?? planFeePercent)
        // A currency named by hand is the point of the override, so it stands; otherwise the
        // account's own currency is the better guess than the last account's.
        if !hasChosenCurrency { entry?.enteredCurrency = chosen.currency }
        if existing == nil, !hasChosenCleared {
            cleared = chosen.type.settlesImmediately ? .cleared : .uncleared
        }
    }

    func choose(currencyCode code: String) {
        entry?.enteredCurrency = CurrencyRegistry.currency(forCode: code)
        hasChosenCurrency = true
    }

    func choose(category chosen: BudgetCategoryModel?) {
        category = chosen
        hasChosenCategory = true
    }

    var isCleared: Bool {
        get { cleared != .uncleared }
        set {
            cleared = newValue ? .cleared : .uncleared
            hasChosenCleared = true
        }
    }

    var isOutflow: Bool {
        get { entry?.isOutflow ?? true }
        set { entry?.isOutflow = newValue }
    }

    // MARK: - Transfers across the budget's edge

    /// Whether this transfer crosses the edge of the budget, in either direction.
    ///
    /// Money moving between two budget accounts is a move and needs no category. Money crossing to
    /// or from a tracked account is leaving the budget or joining it, and must say which envelope —
    /// otherwise it simply vanishes from the plan, which is what happened to a transfer out of a
    /// certificate of deposit that nothing in the budget ever accounted for.
    var destinationNeedsCategory: Bool {
        guard let account, let transferDestination else { return false }
        return account.onBudget != transferDestination.onBudget
    }

    /// True when the money is arriving into the budget rather than leaving it.
    ///
    /// Arriving money has not been earned into an envelope yet, so Ready to Assign is the honest
    /// answer and the picker offers it; leaving money is spending and wants a real category.
    var isEnteringBudget: Bool {
        guard destinationNeedsCategory, let account, let transferDestination else { return false }
        let budgetSideReceives = account.onBudget ? !isOutflow : transferDestination.onBudget
        return budgetSideReceives
    }

    /// What the transfer section says beneath itself.
    var transferNote: String {
        destinationNeedsCategory
            ? (isEnteringBudget
                ? String(localized: "This brings money into the budget, so it needs a category. Ready to Assign leaves it for you to give a job later.")
                : String(localized: "This takes money out of the budget, so it needs a category to come from. Ready to Assign takes it off the top instead of out of an envelope."))
            : String(localized: "Creates two entries: one leaving this account and one arriving in the other.")
    }

    var canSave: Bool {
        guard let entry, account != nil else { return false }
        if isTransfer, transferDestination == nil { return false }
        // A transfer across the edge of the budget without a category is money the plan cannot see.
        if isTransfer, destinationNeedsCategory, category == nil { return false }
        return !entry.isEmpty && !entry.isMissingRate
    }

    // MARK: - Words

    /// The rate and fee as a quiet line under the amount, rather than a panel of its own.
    func rateNote(base: Currency) -> String {
        guard let entry, !entry.isPlainBaseCurrencyEntry, !entry.isMissingRate else { return "" }
        var parts: [String] = []
        if entry.enteredCurrency.code != base.code, let rate = entry.rate {
            let formatted = rate.formatted(.number.precision(.significantDigits(1...6)).locale(.display))
            parts.append("\(1.formatted(.number.locale(.display))) \(entry.enteredCurrency.code) = \(formatted) \(base.code)")
        }
        if let age = entry.rateAgeInDays() {
            parts.append(age == 0 ? String(localized: "updated today") : String(localized: "\(age) days old", locale: .display))
        }
        if entry.feeApplies {
            parts.append(String(localized: "+\(entry.effectiveFeePercent.formatted(.number.locale(.display)))% bank fee"))
        }
        return parts.joined(separator: " · ")
    }

    func convertedSummary(base: Currency) -> String {
        guard let entry else { return "" }
        guard !entry.isMissingRate else { return String(localized: "Rate needed") }
        var summary = "= \(Money(minorUnits: abs(entry.signedBaseAmount), currency: base).formatted())"
        if let fee = entry.feeMoney, !fee.isZero {
            summary += " · " + String(localized: "incl. \(fee.formatted()) fee")
        }
        return summary
    }

    /// What a repeat is about to do.
    ///
    /// Only the occurrence that has not happened yet carries the rule. Setting a repeat on a day that
    /// has already been means this entry stays as it is and a fresh one is scheduled — which looks
    /// exactly like the setting not having taken, unless it is said out loud.
    var repeatNote: String? {
        guard let recurrence else { return nil }
        let next = recurrence.nextDate(after: date, notBefore: .endOfBudgetDay())
        let when = next.formatted(.dateTime.day().month(.abbreviated).year().locale(.display))
        if date <= .endOfBudgetDay() {
            return String(localized: "This one has already happened, so it stays as it is and the next is scheduled for \(when). The repeat moves with it.")
        }
        return String(localized: "Scheduled to repeat. When \(when) arrives it waits for you to approve it, and approving it schedules the one after.")
    }

    // MARK: - Payees

    /// The supermarket is nearly always groceries, so the last choice for this payee is offered.
    /// A category picked by hand is never overwritten.
    func fillCategoryFromPayee(force: Bool = false, payees: [Payee], in context: ModelContext) {
        guard existing == nil, !isTransfer else { return }
        guard force || !hasChosenCategory else { return }
        // Only a name that is already a payee can have a last category, and most keystrokes spell
        // half of one. Checked in memory first, so those skip a fetch of four hundred entries.
        let typed = payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard payees.contains(where: { $0.name.caseInsensitiveCompare(typed) == .orderedSame }) else { return }
        guard let remembered = try? PayeeMemory.lastCategory(forPayeeNamed: payeeName, in: context)
        else { return }
        category = remembered
    }

    // MARK: - Loading and saving

    /// Fills the draft from what it edits, or from the account it starts on. Runs once: returning
    /// from a pushed picker re-runs the view's task, and re-resolving threw away the account just
    /// chosen.
    func prepare(accounts: [Account], lastAccountIdentifier: String, budget: BudgetModel, in context: ModelContext) {
        guard !isPrepared else { return }
        isPrepared = true
        // A plan started by hand has no inflow bucket until an account opens with a balance, and
        // until then the picker had nothing to offer for income.
        _ = try? AccountWriter.inflowCategory(in: context)

        let open = accounts.filter { !$0.closed }
        let resolved = existing?.account
            ?? initialAccount
            ?? accounts.first { $0.identifier.uuidString == lastAccountIdentifier && !$0.closed }
            ?? open.first
        account = resolved
        if existing == nil, resolved?.type.settlesImmediately == true {
            cleared = .cleared
        }

        // The cached rate, which is on disk and instant. Asking the network here meant the editor
        // could not be used until a round trip finished — which on a slow connection is seconds of
        // a screen that is on display and will not respond.
        let quote = try? ExchangeRateService.latestQuote(in: context, baseCode: budget.baseCurrency.code)
        var loaded = AmountEntry(
            baseCurrency: budget.baseCurrency,
            accountCurrency: resolved?.currency ?? budget.baseCurrency,
            feePercent: Decimal(resolved?.fxFeePercentOverride ?? Self.planFeePercent(in: context)),
            quote: quote
        )

        if let existing {
            // An amount already recorded means a currency already settled: moving the transaction to
            // another account must not reinterpret the number that was typed.
            hasChosenCurrency = true
            if let conversion = existing.conversion {
                loaded.enteredCurrency = CurrencyRegistry.currency(forCode: conversion.enteredCurrencyCode)
                loaded.setEnteredAmount(conversion.enteredAmount)
                if conversion.isManualRate {
                    loaded.manualRate = conversion.rateToBase
                    manualRateText = String(conversion.rateToBase)
                }
            } else {
                loaded.enteredCurrency = budget.baseCurrency
                loaded.setEnteredAmount(abs(MinorUnits(existing.amountMinor)))
            }
            loaded.isOutflow = existing.amountMinor < 0
            payeeName = existing.payee?.name ?? ""
            // One category lives between the two rows of a transfer, on the side inside the budget,
            // so it has to be read from there rather than from whichever row was opened.
            category = existing.category ?? budgetSideCategory(of: existing, in: context)
            hasChosenCategory = category != nil
            date = existing.date
            memo = existing.memo
            cleared = existing.cleared
            recurrence = existing.recurrence
            if existing.isTransfer {
                isTransfer = true
                transferDestination = try? TransferWriter.counterpartAccount(of: existing, in: context)
            }
        }
        entry = loaded
    }

    /// Fetches a newer rate behind the screen, once it is usable.
    ///
    /// A rate the user has overridden by hand is left alone: they are saying what their bank actually
    /// charged, which no live rate improves on.
    func refreshRateInBackground(base: Currency, in context: ModelContext) async {
        guard entry?.manualRate == nil else { return }
        let fresher = await ExchangeRateService.refreshIfNeeded(baseCode: base.code, in: context)
        guard let fresher, entry?.manualRate == nil else { return }
        entry?.quote = fresher
    }

    /// Writes the draft. Returns the account it went to, for the next entry to start on, or nil when
    /// there was nothing that could be saved.
    @discardableResult
    func save(payees: [Payee], budget: BudgetModel, in context: ModelContext) -> Account? {
        guard let entry, let account, let conversion = entry.conversion() else { return nil }
        // The picker returns an instant on the picked day; the store wants the day.
        let date = date.asBudgetDay()
        let storedConversion = entry.isPlainBaseCurrencyEntry ? nil : conversion

        if isTransfer, let destination = transferDestination {
            if let existing {
                existing.account = account
                existing.date = date
                existing.amountMinor = Int(entry.signedBaseAmount)
                existing.memo = memo
                existing.cleared = cleared
                existing.conversion = storedConversion
                // The repeat is offered for transfers too, and used to be thrown away here: the
                // picker moved, the save ignored it, and reopening showed "Never" again. Only this
                // side carries it — the counterpart is rebuilt from it.
                existing.recurrence = recurrence
                try? TransferWriter.syncCounterpart(of: existing, destination: destination, in: context)
                // The category goes on whichever side is inside the budget, which is not
                // necessarily the side being edited: withdrawing from a certificate of deposit is
                // opened from the deposit, and the category belongs to the account it arrives in.
                try? TransferWriter.placeCategory(
                    destinationNeedsCategory ? category : nil,
                    onBudgetSideOf: existing,
                    in: context
                )
            } else {
                let fromThisAccount = entry.isOutflow
                TransferWriter.makeTransfer(
                    amountMinor: Int(abs(entry.signedBaseAmount)),
                    from: fromThisAccount ? account : destination,
                    to: fromThisAccount ? destination : account,
                    date: date,
                    memo: memo,
                    cleared: cleared,
                    category: destinationNeedsCategory ? category : nil,
                    conversion: storedConversion,
                    recurrence: recurrence,
                    in: context
                )
            }
        } else {
            let transaction = existing ?? LedgerTransaction(date: date, amountMinor: 0, account: account)
            if existing == nil { context.insert(transaction) }
            transaction.account = account
            transaction.date = date
            transaction.amountMinor = Int(entry.signedBaseAmount)
            transaction.memo = memo
            transaction.cleared = cleared
            transaction.category = category
            transaction.payee = resolvePayee(among: payees, in: context)
            transaction.conversion = storedConversion
            transaction.recurrence = recurrence
            if existing != nil { try? TransferWriter.syncCounterpart(of: transaction, in: context) }
        }

        try? context.save()
        budget.refresh(in: context)
        // A first repeat is when a reminder obviously helps: the day it comes due.
        if recurrence != nil { ReminderScheduler.shared.askIfUndecided() }
        return account
    }

    func delete(budget: BudgetModel, in context: ModelContext) {
        guard let existing, !hasDeleted else { return }
        hasDeleted = true
        try? TransactionWriter.delete(existing, in: context)
        budget.refresh(in: context)
    }

    static func planFeePercent(in context: ModelContext) -> Double {
        (try? context.planSettings().defaultFXFeePercent) ?? 0
    }

    /// The category carried by the other half of a transfer, when that half is the budget's side.
    private func budgetSideCategory(of transaction: LedgerTransaction, in context: ModelContext) -> BudgetCategoryModel? {
        guard transaction.isTransfer,
              let sides = try? TransferWriter.pair(of: transaction, in: context)
        else { return nil }
        return sides.first { $0.account?.onBudget == true }?.category
    }

    private func resolvePayee(among payees: [Payee], in context: ModelContext) -> Payee? {
        let trimmed = payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // The one the sync merge keeps, when two devices each met this payee.
        if let existing = SyncMerge.survivingPayees(payees)
            .first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmed) == .orderedSame }) {
            existing.lastUsedAt = Date()
            return existing
        }
        let created = Payee(name: trimmed, lastUsedAt: Date())
        context.insert(created)
        return created
    }
}

extension Array where Element == BudgetCategoryModel {
    /// What a transaction can be given, in the order a picker offers it.
    ///
    /// Ready to Assign is always offered, first. It is where income goes — a salary has no envelope
    /// yet — and it was once offered only on a transfer across the budget's edge, which left no way
    /// to record being paid. On a transfer it answers either direction: arriving with no job yet, or
    /// leaving without coming out of any one envelope.
    ///
    /// The rest follow the plan's own order, group by group. Sorting on the category's order alone
    /// interleaved the groups, since every group numbers its categories from zero.
    var selectable: [BudgetCategoryModel] {
        filter { $0.kind == .inflowReadyToAssign }
            + filter { $0.kind == .normal && !$0.hidden }
            .sorted { ($0.group?.order ?? .max, $0.order) < ($1.group?.order ?? .max, $1.order) }
    }
}
