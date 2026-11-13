import EmbersData
import SwiftData
import SwiftUI

/// What the budget's window does over its life: the first recompute, the launch catch-up once it is
/// safe, taking in another device's changes, and keeping reminders in step.
///
/// One modifier for the iPhone and the Mac. The order and the guard here are what stop a new device
/// from seeding a second starter plan beside the one on its way down from iCloud
/// (docs/data-model/syncing.md), and two copies of that would drift.
struct BudgetLifecycle: ViewModifier {
    let budget: BudgetModel
    /// Where a tapped reminder asks to go.
    let onRoute: (AppTab) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(CloudSync.self) private var cloud
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isSplashShowing) private var isSplashShowing
    @State private var hasCaughtUp = false
    private let reminders = ReminderScheduler.shared

    func body(content: Content) -> some View {
        content
            .environment(budget)
            .task {
                budget.refresh(in: modelContext)
                await cloud.start()
                catchUpOnceAllowed()
            }
            .onChange(of: cloud.status) { _, _ in catchUpOnceAllowed() }
            .onChange(of: cloud.importsCompleted) { _, _ in
                budget.takeInArrivals(in: modelContext)
                budget.withdrawPlanCurrencyQuestionIfSettled(in: modelContext)
                catchUpOnceAllowed()
            }
            // Every recompute reads what reminders are planned from; planning again is cheap, and
            // touches the system only when the answer differs.
            .onChange(of: budget.reminderFacts) { _, facts in
                if let facts { reminders.replan(facts) }
            }
            // A tapped reminder opens on what it was about. Taken from the change, not the closure.
            .onChange(of: reminders.route) { _, route in
                guard let route else { return }
                onRoute(route)
                reminders.route = nil
            }
            // Approved or skipped from a notification: the figures on screen are behind.
            .onChange(of: reminders.changes) { _, _ in budget.refresh(in: modelContext) }
            // The day may have turned while the app was away, and with it what is due.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { budget.refresh(in: modelContext) }
            }
            // Held back while the splash is up: the splash is a view in the window, and a sheet is
            // drawn over the whole window, so it would rise over the launch animation. Held back too
            // while anything is arriving from iCloud: a plan comes down in pieces, and one that looked
            // empty may be a plan whose amounts have not landed yet. The budget is put into the
            // environment above this, so the sheet is handed it again.
            .sheet(isPresented: Binding(
                get: { budget.isChoosingPlanCurrency && !isSplashShowing && !cloud.isImporting && !cloud.isFirstDownload },
                set: { if !$0 { budget.isChoosingPlanCurrency = false } }
            )) {
                PlanCurrencyPrompt(suggested: budget.suggestedPlanCurrency).environment(budget)
            }
    }

    /// The launch catch-up, held back on a new device until the plan has come down from iCloud:
    /// run against an empty or half-arrived store, it seeds a starter plan, a credit card group and
    /// repeats of its own that then arrive beside the real ones.
    private func catchUpOnceAllowed() {
        guard !hasCaughtUp, cloud.mayWriteAtLaunch() else { return }
        hasCaughtUp = true
        budget.catchUpSchedules(in: modelContext)
        budget.refresh(in: modelContext)
    }
}

extension View {
    func budgetLifecycle(_ budget: BudgetModel, onRoute: @escaping (AppTab) -> Void) -> some View {
        modifier(BudgetLifecycle(budget: budget, onRoute: onRoute))
    }
}

extension EnvironmentValues {
    /// Whether the iPhone's splash is still over the window. The Mac has none.
    @Entry var isSplashShowing = false
}
