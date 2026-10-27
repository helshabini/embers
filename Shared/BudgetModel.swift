import EmbersCore
import EmbersData
import Observation
import SwiftData
import SwiftUI

/// Holds the computed budget for the views.
///
/// The engine recomputes the whole budget from a snapshot rather than maintaining running totals, so
/// there is no incremental state to get out of step with the store. Recomputing the real 10,800-entry
/// budget takes well under a second, so views ask for a refresh after edits instead of the store
/// trying to patch derived values.
@MainActor
@Observable
final class BudgetModel {
    private(set) var result: BudgetResult?
    /// Bumped whenever the budget has been recomputed. Screens that read the store themselves watch
    /// this to know when what they are showing has gone stale.
    private(set) var revision = 0
    private(set) var baseCurrency: Currency = CurrencyRegistry.usd
    private(set) var lastError: String?
    /// Transactions after this are upcoming: entered, but not yet part of any balance.
    private(set) var activityCutoff: Date = .endOfBudgetDay()
    var visibleMonth: YearMonth = .current()
    /// Scheduled entries whose day has come, waiting to be approved or skipped. A transfer counts once.
    private(set) var dueForApprovalCount = 0
    /// What reminders are planned from, read with every recompute.
    private(set) var reminderFacts: ReminderFacts?

    /// Whether the money in this entry has moved: dated today or earlier, and not awaiting approval.
    func hasHappened(_ transaction: LedgerTransaction) -> Bool {
        transaction.hasHappened(asOf: activityCutoff)
    }

    /// Entries that have happened in a budget account with no category, which the plan cannot see.
    var uncategorized: [UUID] { result?.uncategorized ?? [] }

    /// What the Transactions tab's badge counts: things waiting for a decision.
    var needsAttentionCount: Int { uncategorized.count + dueForApprovalCount }

    /// The recompute in flight. A newer one replaces it rather than queueing behind it: only the
    /// latest answer is wanted, and three keystrokes should not mean three full recomputes.
    private var refreshTask: Task<Void, Never>?

    /// Rolls repeating entries forward. Scans the register, so it runs once at launch rather than
    /// on every refresh.
    /// Runs once at launch, while the splash is still up, so its scan of the register is not felt.
    /// Brings the credit card group in step with the accounts.
    ///
    /// It is not a list anyone maintains: one category per open card, and a closed card's category
    /// moved to Hidden with its figures intact. Run wherever an account can have changed, since that
    /// is the only thing it follows.
    func syncCreditCardCategories(in context: ModelContext) {
        try? CategoryWriter.syncCreditCardCategories(in: context)
    }

    /// What the plan could not decide for itself, found at launch and waiting for an answer.
    private(set) var findings = BudgetAudit.Findings()

    /// Runs once at launch, while the splash is still up, so its scan of the register is not felt.
    ///
    /// Everything that can be put right without a decision is: transfers written before both halves
    /// knew about each other, credit card categories out of step with the accounts, and categories
    /// left on the tracked side of a boundary transfer where they count for nothing. What is left
    /// needs a person, and is reported rather than guessed at.
    func catchUpSchedules(in context: ModelContext) {
        // A plan opened for the first time starts with groups to fill, not a blank page.
        try? CategoryWriter.seedStarterPlan(in: context)
        try? BudgetAudit.repair(in: context)
        try? RecurrenceWriter.markScheduled(in: context, asOf: .endOfBudgetDay())
        try? RecurrenceWriter.advanceDueOccurrences(in: context, asOf: .endOfBudgetDay())
        recheck(in: context)
    }

    /// Takes in what has arrived from another device.
    ///
    /// The figures on screen were worked out before it came, and it may hold what this device also
    /// made for itself while the two were out of touch — see `SyncMerge`.
    func takeInArrivals(in context: ModelContext) {
        try? SyncMerge.mergeDuplicates(in: context)
        recheck(in: context)
        refresh(in: context)
    }

    /// Looks again for anything that needs a decision.
    func recheck(in context: ModelContext) {
        findings = (try? BudgetAudit.findings(in: context)) ?? BudgetAudit.Findings()
    }

    /// Recomputes the budget without holding up the screen.
    ///
    /// Reading the store is the expensive part — around a tenth of a second for ten thousand entries
    /// on a Mac, and several times that on a phone — while the engine itself takes single-figure
    /// milliseconds. Doing that on the main thread after every save is what made saving feel slow,
    /// so the read and the compute happen on their own context and only the answer comes back.
    func refresh(in context: ModelContext) {
        activityCutoff = .endOfBudgetDay()
        // Whatever was just written with a future date is a schedule, and must wait for approval
        // when its day comes. Marked before the save, so the recompute below sees it.
        try? RecurrenceWriter.markScheduled(in: context, asOf: activityCutoff)
        // A background context cannot see what has not been written yet.
        if context.hasChanges { try? context.save() }

        // Read, not made: `planSettings()` creates a row when there is none, and a refresh runs at
        // launch, before a new device may write anything. Until the plan's settings arrive the
        // default currency stands.
        var settingsDescriptor = FetchDescriptor<PlanSettings>()
        settingsDescriptor.fetchLimit = 1
        if let settings = try? context.fetch(settingsDescriptor).first {
            baseCurrency = settings.baseCurrency
        }
        dueForApprovalCount = (try? RecurrenceWriter.dueForApproval(in: context, asOf: activityCutoff).count) ?? 0

        let container = context.container
        let cutoff = activityCutoff
        let month = visibleMonth
        let currency = baseCurrency
        let lastBackupAt = ReminderScheduler.lastBackupAt

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let computed: Result<(BudgetResult, ReminderFacts?), any Error> = await Task.detached(
                priority: .userInitiated
            ) {
                do {
                    let background = ModelContext(container)
                    let input = try BudgetInputBuilder.build(from: background)
                    let result = BudgetEngine().compute(input, asOf: cutoff, through: month)
                    // Read here, beside the recompute and from its answer, so that keeping the
                    // reminders current costs the screen nothing. Always against this month: a
                    // reminder is about what is coming, whichever month the Plan is showing.
                    let current = YearMonth.current()
                    let facts = try? ReminderFactsReader.read(
                        from: background,
                        result: current <= month
                            ? result
                            : BudgetEngine().compute(input, asOf: cutoff, through: current),
                        asOf: cutoff,
                        month: current,
                        currency: currency,
                        lastBackupAt: lastBackupAt
                    )
                    return .success((result, facts))
                } catch {
                    return .failure(error)
                }
            }.value

            guard !Task.isCancelled, let self else { return }
            switch computed {
            case let .success((result, facts)):
                self.result = result
                if let facts { self.reminderFacts = facts }
                self.revision &+= 1
                self.lastError = nil
            case let .failure(error):
                self.lastError = String(describing: error)
            }
        }
    }

    /// Waits for any recompute in flight. For tests and for anything that must read settled figures.
    func settle() async {
        await refreshTask?.value
    }

    func money(_ minorUnits: MinorUnits) -> String {
        Money(minorUnits: minorUnits, currency: baseCurrency).formatted()
    }

    func balance(of account: Account) -> MinorUnits {
        result?.accountBalances[account.identifier] ?? 0
    }

    /// Entered transactions dated in the future, which are not part of the balance yet.
    func upcoming(of account: Account) -> MinorUnits {
        result?.upcoming(for: account.identifier) ?? 0
    }

    /// What a closed card's payment category holds now beyond what the card still owes: money set
    /// aside for a payment nobody will make.
    ///
    /// Closing a card hides that category, but its balance stays among the envelopes, out of sight.
    /// The closing guard keeps new ones from happening; this finds those closed before it.
    func setAsideForNothing(by category: BudgetCategoryModel) -> MinorUnits {
        guard category.kind == .creditCardPayment, let card = category.linkedAccount, card.closed else {
            return 0
        }
        let owed = max(0, -(balance(of: card) + upcoming(of: card)))
        let held = result?.state(of: category.identifier, in: .current()).available ?? 0
        return max(0, held - owed)
    }

    /// What is entered for this category later in the visible month and has not happened yet.
    func upcoming(of category: BudgetCategoryModel) -> MinorUnits {
        result?.upcoming(of: category.identifier, in: visibleMonth) ?? 0
    }

    /// How the category stands in the visible month, as its colour shows it.
    func status(of category: BudgetCategoryModel) -> CategoryStatus {
        CategoryStatus(state(of: category), upcoming: upcoming(of: category))
    }

    /// What assigning would make this category whole this month: an overspend covered, or what is
    /// still to come funded.
    func shortfall(of category: BudgetCategoryModel) -> MinorUnits {
        switch status(of: category) {
        case .overspent, .creditOverspent: max(0, -state(of: category).available)
        case let .underfunded(needed): needed
        case .empty, .funded: 0
        }
    }

    /// What a card's payment categories hold this month. Closing the card would hide them.
    func heldForPayment(of card: Account) -> MinorUnits {
        guard card.type.isCredit else { return 0 }
        return (card.paymentCategories ?? []).reduce(0) { total, category in
            total + max(0, result?.state(of: category.identifier, in: .current()).available ?? 0)
        }
    }

    func state(of category: BudgetCategoryModel) -> CategoryMonthState {
        result?.state(of: category.identifier, in: visibleMonth) ?? CategoryMonthState()
    }

    var netWorth: MinorUnits { result?.netWorth ?? 0 }

    /// The years the budget spans, with a little room to plan ahead: what a month picker offers.
    var budgetYears: ClosedRange<Int> {
        let months = result?.monthsInOrder ?? []
        let thisYear = YearMonth.current().year
        let first = min(months.first?.year ?? thisYear, thisYear)
        let last = max(months.last?.year ?? thisYear, thisYear + 1)
        return first...last
    }

    var readyToAssign: MinorUnits {
        result?.readyToAssign(in: visibleMonth) ?? 0
    }

    func total(of accounts: [Account]) -> MinorUnits {
        accounts.reduce(0) { $0 + balance(of: $1) }
    }
}
