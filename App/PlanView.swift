import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// The envelope budget: what each category has assigned, spent, and left this month.
struct PlanView: View {
    @Environment(CloudSync.self) private var cloud
    @Environment(BudgetModel.self) private var budget
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CategoryGroup.order) private var groups: [CategoryGroup]
    @State private var assigning: BudgetCategoryModel?
    @State private var showsHidden = false
    @State private var isEditingPlan = false
    @State private var isPickingMonth = false

    var body: some View {
        NavigationStack {
            List {
                readyToAssignSection
                ForEach(visibleGroups) { group in
                    groupSection(group)
                }
            }
            .navigationTitle("Plan")
            .sheet(isPresented: $isEditingPlan) { EditPlanView() }
            .sheet(isPresented: $isPickingMonth) {
                MonthPickerView(
                    selected: budget.visibleMonth,
                    available: budget.budgetYears
                ) { month in
                    budget.visibleMonth = month
                    budget.refresh(in: modelContext)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isEditingPlan = true
                    } label: {
                        Label("Edit Plan", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("edit-plan")
                }
                // One control, so the month sits where the month should sit. As three separate
                // items it was placed against whatever the leading and trailing ones measured, and
                // some months came out off centre while others did not.
                ToolbarItem(placement: .principal) {
                    MonthNavigator(
                        month: budget.visibleMonth,
                        onStep: { step(by: $0) },
                        onTapMonth: { isPickingMonth = true }
                    )
                }
            }
            .overlay {
                // Empty because it is still arriving, not because there is nothing.
                if groups.isEmpty, cloud.isFirstDownload {
                    FirstDownloadNotice(isProminent: true)
                } else if groups.isEmpty {
                    ContentUnavailableView(
                        "Nothing to plan yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Import a YNAB export to bring your categories across.")
                    )
                }
            }
            .sheet(item: $assigning) { category in
                CategoryDetailView(category: category, month: budget.visibleMonth)
            }
        }
    }

    private var readyToAssignSection: some View {
        // Coloured by the one question it answers, as YNAB does: money left to give a job, none, or
        // more given out than there is. An "over-committed" warning used to sit here too; in a budget
        // that balances it says exactly what a red figure says, and when the books did not balance
        // it named the wrong cause.
        FlameHeader(
            title: String(localized: "Ready to Assign"),
            subtitle: budget.visibleMonth.displayName,
            background: readyToAssignBackground,
            shadow: readyToAssignShadow
        ) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(budget.money(budget.readyToAssign))
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                if budget.readyToAssign < 0 {
                    Text("You assigned more than you have")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.9))
                        .accessibilityIdentifier("plan-assigned-too-much")
                } else if budget.readyToAssign == 0 {
                    Text("All money assigned")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.9))
                } else {
                    // Every state carries a line, so the card is the same height whatever its colour.
                    Text("All good")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.9))
                }
                // Money that moved without a category is invisible to every figure here, so Ready to
                // Assign stops matching the accounts. Said where that figure is read.
                if !budget.uncategorized.isEmpty {
                    Label(
                        String(localized: "\(budget.uncategorized.count) uncategorized transactions", locale: .display),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("plan-uncategorized-warning")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func groupSection(_ group: CategoryGroup) -> some View {
        Section {
            ForEach(categories(in: group)) { category in
                Button {
                    assigning = category
                } label: {
                    CategoryRow(category: category)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if shortfall(of: category) > 0 {
                        Button {
                            cover(category)
                        } label: {
                            Label("Cover", systemImage: "flame.fill")
                        }
                        .tint(Flame.ember)
                    }
                }
            }
        } header: {
            HStack {
                Text(group.displayName)
                Spacer()
                Text(budget.money(groupAvailable(group)))
            }
        }
    }

    private var readyToAssignShadow: Color {
        if budget.readyToAssign > 0 { return Flame.inflow }
        return budget.readyToAssign < 0 ? Flame.outflow : Color(white: 0.4)
    }

    private var readyToAssignBackground: LinearGradient {
        if budget.readyToAssign > 0 { return Flame.inflowGradient }
        return budget.readyToAssign < 0 ? Flame.outflowGradient : Flame.neutralGradient
    }

    private var visibleGroups: [CategoryGroup] {
        groups.filter { group in
            guard showsHidden || !group.hidden else { return false }
            return !categories(in: group).isEmpty
        }
    }

    /// The inflow bucket is not an envelope, so it never appears in the Plan.
    private func categories(in group: CategoryGroup) -> [BudgetCategoryModel] {
        (group.categories ?? [])
            .filter { $0.kind != .inflowReadyToAssign && (showsHidden || !$0.hidden) }
            .sorted { $0.order < $1.order }
    }

    private func groupAvailable(_ group: CategoryGroup) -> MinorUnits {
        categories(in: group).reduce(0) { total, category in
            total + budget.state(of: category).available
        }
    }

    private func shortfall(of category: BudgetCategoryModel) -> MinorUnits {
        budget.shortfall(of: category)
    }

    /// Assigns exactly the shortfall: an overspent category lands on zero, and one short of what is
    /// still to come this month holds exactly enough for it.
    ///
    /// Ready to Assign is allowed to go negative: refusing would hide the overspend rather than fix
    /// it, and seeing Ready to Assign in red is the signal to move money from somewhere else.
    private func cover(_ category: BudgetCategoryModel) {
        let amount = shortfall(of: category)
        guard amount > 0 else { return }
        try? AssignmentWriter.adjustAssigned(
            by: amount, category: category, month: budget.visibleMonth, in: modelContext
        )
        budget.refresh(in: modelContext)
    }

    private func step(by months: Int) {
        budget.visibleMonth = budget.visibleMonth.adding(months: months)
        budget.refresh(in: modelContext)
    }
}

struct CategoryRow: View {
    let category: BudgetCategoryModel
    @Environment(BudgetModel.self) private var budget

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.displayName)
                if state.activity != 0 {
                    Text("spent \(budget.money(-state.activity))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(budget.money(state.available))
                    .monospacedDigit()
                    .foregroundStyle(availableColor)
                if case let .underfunded(needed) = budget.status(of: category) {
                    Text("\(budget.money(needed)) more needed")
                        .font(.caption2)
                        .foregroundStyle(Flame.glow)
                        .accessibilityIdentifier("category-needs-more")
                } else if state.assigned != 0 {
                    Text("assigned \(budget.money(state.assigned))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var state: CategoryMonthState { budget.state(of: category) }

    private var availableColor: Color { budget.status(of: category).color }
}
