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
    /// The Assigned figure being typed, with the keypad up.
    @State private var assignSession: AssignSession?
    /// Whether the column headings above the first group have scrolled away, and a copy is pinned
    /// in their place.
    @State private var headingsPinned = false
    /// Where the headings in the list end, and the list itself, so the pinned copy lines up with
    /// them. Measured: the list's side margin differs between an iPhone and an iPad.
    @State private var headingsTrailingEdge: CGFloat?
    @State private var listTrailingEdge: CGFloat?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    readyToAssignSection
                    ForEach(visibleGroups) { group in
                        groupSection(group, isFirst: group.id == visibleGroups.first?.id)
                    }
                    // Room for the last rows to be scrolled up above the keypad. Room in the safe
                    // area alone was not enough: the list scrolled a late row there, then pulled
                    // back within its own content and put it under the keypad again.
                    if assignSession != nil {
                        Color.clear
                            .frame(height: PlanColumns.keypadRoom)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                // Scrolled down a long plan, the figures on each row were two numbers with nothing
                // to say which was which.
                .overlay(alignment: .top) {
                    if headingsPinned, !visibleGroups.isEmpty {
                        columnHeadings
                            .padding(.horizontal, headingsTrailingGap)
                            .padding(.vertical, 6)
                            .background(.bar)
                            .transition(.opacity)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("plan-pinned-headings")
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { listTrailingEdge = $0 }
                .assignKeypad($assignSession, onDone: finishAssigning)
                .onChange(of: assignSession?.category.persistentModelID) { _, id in
                    guard let id else { return }
                    keepAboveKeypad(id, proxy)
                }
            }
            .navigationTitle("Plan")
            .sheet(isPresented: $isEditingPlan) { EditPlanView() }
            .sheet(isPresented: $isPickingMonth) {
                MonthPickerView(
                    selected: budget.visibleMonth,
                    available: budget.budgetYears
                ) { month in
                    // Saved into the month it was typed for, before that month leaves the screen.
                    finishAssigning()
                    budget.visibleMonth = month
                    budget.refresh(in: modelContext)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        // Saved first: the plan editor can delete the category being typed into.
                        finishAssigning()
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

    /// What the two figures on each row are. Without them the Assigned field was one more number.
    private var columnHeadings: some View {
        HStack(spacing: PlanColumns.spacing) {
            Spacer()
            Text("Assigned").frame(width: PlanColumns.assigned, alignment: .trailing)
            Text("Available").frame(width: PlanColumns.available, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    /// Brings the row being assigned to into the middle of what the keypad leaves. Straight away it
    /// was centred in the whole screen, the keypad not yet up, and the keypad then covered it. After
    /// the keypad has settled, as the transaction editor does for its amount.
    private func keepAboveKeypad(_ id: PersistentIdentifier, _ proxy: ScrollViewProxy) {
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard assignSession?.category.persistentModelID == id else { return }
            withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
        }
    }

    private func groupSection(_ group: CategoryGroup, isFirst: Bool) -> some View {
        Section {
            ForEach(categories(in: group)) { category in
                // Two targets in one row: the figure to assign, laid over the room the row leaves
                // for it, and the rest of the row for what is behind it. Plain buttons, or a list
                // row hands every tap to all of them.
                Button {
                    finishAssigning()
                    assigning = category
                } label: {
                    CategoryRow(category: category)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("category-row")
                .overlay(alignment: .trailing) {
                    Button {
                        startAssigning(category)
                    } label: {
                        AssignedField(
                            amount: budget.money(budget.state(of: category).assigned),
                            isEditing: assignSession?.category.persistentModelID == category.persistentModelID
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(width: PlanColumns.assigned)
                    .padding(.trailing, PlanColumns.available + PlanColumns.spacing)
                    .accessibilityIdentifier("assigned-field")
                    .accessibilityLabel(Text("Assigned to \(category.displayName)"))
                    .accessibilityValue(Text(budget.money(budget.state(of: category).assigned)))
                }
                .id(category.persistentModelID)
                // Narrower at the trailing edge than a list's own, so the figures hug it and the
                // name has the room.
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: PlanColumns.trailingInset))
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
            VStack(spacing: 6) {
                // In the first group's header rather than a row of their own: as a row, the section
                // spacing opened a wide gap between them and the figures they name.
                if isFirst {
                    columnHeadings
                        .onScrollVisibilityChange(threshold: 0.01) { visible in
                            withAnimation(.easeOut(duration: 0.15)) { headingsPinned = !visible }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: {
                            headingsTrailingEdge = $0
                        }
                }
                HStack(spacing: PlanColumns.spacing) {
                    Text(group.displayName)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        Text(budget.money(groupAssigned(group)))
                            .frame(width: PlanColumns.assigned, alignment: .trailing)
                        Text(budget.money(groupAvailable(group)))
                            .frame(width: PlanColumns.available, alignment: .trailing)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
            }
            .padding(.trailing, PlanColumns.trailingInset - 20)
        }
    }

    private var headingsTrailingGap: CGFloat {
        guard let list = listTrailingEdge, let headings = headingsTrailingEdge, list > headings else { return 28 }
        return list - headings
    }

    /// Opens the keypad on a category, saving whatever was being typed into another first.
    private func startAssigning(_ category: BudgetCategoryModel) {
        if assignSession?.category.persistentModelID == category.persistentModelID { return }
        // A sum with no answer stays up, its Assign disabled, rather than vanishing unsaved.
        if let open = assignSession, open.calculator.result == nil { return }
        // Saved before the next is read, so its figure takes in what was just assigned.
        let wasOpen = assignSession != nil
        assignSession?.commit(in: modelContext, budget: budget)
        let next = AssignSession(
            category: category,
            month: budget.visibleMonth,
            shown: budget.state(of: category).assigned,
            currency: budget.baseCurrency
        )
        // Moving to another row keeps the keypad up and changes what it types into. Put away and
        // brought back in one go, the two animations met, and a half-faded keypad was left on
        // screen for seconds.
        if wasOpen {
            assignSession = next
        } else {
            withAnimation(.snappy) { assignSession = next }
        }
    }

    private func finishAssigning() {
        guard let session = assignSession else { return }
        session.commit(in: modelContext, budget: budget)
        withAnimation(.snappy) { assignSession = nil }
    }

    private func groupAssigned(_ group: CategoryGroup) -> MinorUnits {
        categories(in: group).reduce(0) { $0 + budget.state(of: $1).assigned }
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
        finishAssigning()
        budget.visibleMonth = budget.visibleMonth.adding(months: months)
        budget.refresh(in: modelContext)
    }
}

struct CategoryRow: View {
    let category: BudgetCategoryModel
    @Environment(BudgetModel.self) private var budget

    var body: some View {
        // Name, then room for the Assigned field the Plan lays over it, then Available: the order
        // and widths of the headings above, so each figure sits under its own.
        // Every line is one line, so every row is the same height: a name wrapping to two made its
        // row, and the Assigned field laid over it, taller than the rest.
        HStack(spacing: PlanColumns.spacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.displayName)
                    .font(.callout)
                    .minimumScaleFactor(0.75)
                if state.activity != 0 {
                    Text("spent \(budget.money(-state.activity))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: PlanColumns.assigned, height: 1)
            VStack(alignment: .trailing, spacing: 2) {
                Text(budget.money(state.available))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(availableColor)
                if case let .underfunded(needed) = budget.status(of: category) {
                    Text("\(budget.money(needed)) more needed")
                        .font(.caption2)
                        .foregroundStyle(Flame.glow)
                        .accessibilityIdentifier("category-needs-more")
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: PlanColumns.available, alignment: .trailing)
        }
        .frame(minHeight: PlanColumns.rowHeight)
        .contentShape(Rectangle())
    }

    private var state: CategoryMonthState { budget.state(of: category) }

    private var availableColor: Color { budget.status(of: category).color }
}

/// The widths the Plan's figures line up in, row and heading alike.
enum PlanColumns {
    /// $1,234.56 fits both at full size; larger figures shrink rather than wrap.
    static let assigned: CGFloat = 88
    static let available: CGFloat = 80
    static let spacing: CGFloat = 6
    /// Tall enough for a name with "spent" under it, so rows with and without match.
    static let rowHeight: CGFloat = 40
    /// A category row's trailing inset, against a list's own 20.
    static let trailingInset: CGFloat = 12
    /// About half the keypad: enough to bring the last row to the middle of what it leaves.
    static let keypadRoom: CGFloat = 200
}
