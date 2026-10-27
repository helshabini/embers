import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// One line of the Plan, read when the figures are: a group with its totals, or a category.
///
/// The cells read only this. A category can be deleted from the plan editor while the table still
/// holds its row, and reading a deleted model is fatal.
struct PlanRow: Identifiable {
    let id: UUID
    let name: String
    let category: BudgetCategoryModel?
    /// The group a group row stands for; nil on a category's row.
    var group: CategoryGroup? = nil
    let assigned: MinorUnits
    let activity: MinorUnits
    let available: MinorUnits
    let status: CategoryStatus?
    /// What assigning would make it whole: an overspend covered, or what is still to come funded.
    let shortfall: MinorUnits
    var children: [PlanRow] = []

    var isGroup: Bool { category == nil }
}

/// The envelope budget as a desktop table: every category's Assigned, Activity and Available for the
/// month, groups folding away, Assigned typed straight into its cell.
///
/// The phone's tap-a-category sheet is the inspector on the right, so the table stays in view while
/// one category is looked into.
struct PlanScreen: View {
    @Environment(CloudSync.self) private var cloud
    @Environment(BudgetModel.self) private var budget
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CategoryGroup.order) private var groups: [CategoryGroup]

    @State private var selection: UUID?
    @State private var isPickingMonth = false
    @AppStorage("plan.showsInspector") private var showsInspector = true
    @AppStorage("plan.showsHidden") private var showsHidden = false
    /// Groups folded away. Not remembered across launches: the plan should open whole.
    @State private var collapsed: Set<UUID> = []
    @State private var edit: PlanEdit?

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            table
        }
        .navigationTitle("Plan")
        .toolbar { toolbar }
        .modifier(PlanEditing(edit: $edit))
        .alert("Can't do that", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button("OK") { refusal = nil }
        } message: {
            Text(refusal ?? "")
        }
        .inspector(isPresented: $showsInspector) {
            Group {
                if let category = selectedCategory {
                    CategoryInspector(category: category, month: budget.visibleMonth)
                } else {
                    ContentUnavailableView(
                        "No category selected",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Select a category to see what it holds and what hit it.")
                    )
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 320, max: 440)
        }
        .overlay {
            // While the budget is arriving the sidebar says so; saying it here too was the same
            // message twice.
            if groups.isEmpty, !cloud.isFirstDownload {
                ContentUnavailableView(
                    "Nothing to plan yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Import a YNAB export to bring your categories across.")
                )
            }
        }
    }

    // MARK: - The month's figures

    private var summary: some View {
        let month = budget.result?.months[budget.visibleMonth]
        return HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ready to Assign")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(budget.money(budget.readyToAssign))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Flame.amountColor(budget.readyToAssign))
            }
            figure(String(localized: "Assigned"), month?.assignedTotal ?? 0)
            figure(String(localized: "Activity"), month?.activityTotal ?? 0)
            Spacer()
            if budget.readyToAssign < 0 {
                Label("You assigned more than you have", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Flame.outflow)
                    .accessibilityIdentifier("plan-assigned-too-much")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func figure(_ title: String, _ amount: MinorUnits) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(budget.money(amount))
                .font(.title3)
                .monospacedDigit()
        }
    }

    // MARK: - The table

    private var table: some View {
        Table(of: PlanRow.self, selection: $selection) {
            TableColumn("Category") { row in
                Text(row.name)
                    .fontWeight(row.isGroup ? .semibold : .regular)
                    .lineLimit(1)
            }
            .width(min: 160, ideal: 260)

            TableColumn("Assigned") { row in
                if let category = row.category {
                    AssignedField(assigned: row.assigned, currency: budget.baseCurrency) { amount in
                        assign(amount, shown: row.assigned, to: category)
                    }
                } else {
                    amount(row.assigned).fontWeight(.semibold)
                }
            }
            .width(min: 90, ideal: 120)

            TableColumn("Activity") { row in
                amount(row.activity)
                    .foregroundStyle(row.activity == 0 ? .secondary : .primary)
                    .fontWeight(row.isGroup ? .semibold : .regular)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Available") { row in
                if let status = row.status {
                    AvailablePill(amount: budget.money(row.available), status: status, shortfall: row.shortfall)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    amount(row.available).fontWeight(.semibold)
                }
            }
            .width(min: 100, ideal: 130)
        } rows: {
            ForEach(rows) { group in
                DisclosureTableRow(group, isExpanded: expansion(of: group.id)) {
                    ForEach(group.children) { row in
                        TableRow(row)
                            .draggable(PlanDrag.category(row.id).text)
                            .dropDestination(for: String.self) { items in drop(items, onto: row) }
                    }
                }
                .draggable(PlanDrag.group(group.id).text)
                .dropDestination(for: String.self) { items in drop(items, onto: group) }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first {
                if let row = categoryRow(id), let category = row.category {
                    categoryMenu(row, category)
                } else if let group = rows.first(where: { $0.id == id })?.group {
                    groupMenu(group)
                }
            }
        } primaryAction: { ids in
            selection = ids.first
            showsInspector = true
        }
        .accessibilityIdentifier("plan-table")
    }

    private func amount(_ minorUnits: MinorUnits) -> some View {
        Text(budget.money(minorUnits))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func expansion(of group: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(group) },
            set: { open in
                if open { collapsed.remove(group) } else { collapsed.insert(group) }
            }
        )
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // One control, so the month sits where the month should sit: as three separate items the
        // phone placed it against whatever its neighbours measured.
        ToolbarItem(placement: .principal) {
            MonthNavigator(
                month: budget.visibleMonth,
                onStep: { step(by: $0) },
                onTapMonth: { isPickingMonth = true }
            )
            .popover(isPresented: $isPickingMonth, arrowEdge: .bottom) {
                MonthPickerView(selected: budget.visibleMonth, available: budget.budgetYears) { month in
                    budget.visibleMonth = month
                    budget.refresh(in: modelContext)
                }
            }
        }
        ToolbarItem {
            Button {
                edit = .addGroup
            } label: {
                Label("Add Group", systemImage: "folder.badge.plus")
            }
            .help("Add a group of categories")
            .accessibilityIdentifier("add-group")
        }
        ToolbarItem {
            Toggle(isOn: $showsHidden) {
                Label("Show Hidden Categories", systemImage: "eye")
            }
        }
        ToolbarItem {
            Button {
                showsInspector.toggle()
            } label: {
                Label("Category Details", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the selected category's details")
        }
    }

    // MARK: - Reading

    /// Groups with their categories, as the Plan lists them. The inflow bucket is not an envelope,
    /// so it never appears.
    private var rows: [PlanRow] {
        groups.compactMap { group -> PlanRow? in
            guard showsHidden || !group.hidden else { return nil }
            let categories = (group.categories ?? [])
                .filter { $0.kind != .inflowReadyToAssign && (showsHidden || !$0.hidden) }
                .sorted { $0.order < $1.order }
            guard !categories.isEmpty else { return nil }
            let children = categories.map { category in
                let state = budget.state(of: category)
                return PlanRow(
                    id: category.identifier,
                    name: category.displayName,
                    category: category,
                    assigned: state.assigned,
                    activity: state.activity,
                    available: state.available,
                    status: budget.status(of: category),
                    shortfall: budget.shortfall(of: category)
                )
            }
            return PlanRow(
                id: group.identifier,
                name: group.displayName,
                category: nil,
                group: group,
                assigned: children.reduce(0) { $0 + $1.assigned },
                activity: children.reduce(0) { $0 + $1.activity },
                available: children.reduce(0) { $0 + $1.available },
                status: nil,
                shortfall: 0,
                children: children
            )
        }
    }

    private func categoryRow(_ id: UUID) -> PlanRow? {
        rows.lazy.flatMap(\.children).first { $0.id == id }
    }

    private var selectedCategory: BudgetCategoryModel? {
        guard let selection, let category = categoryRow(selection)?.category, !category.isDeleted else { return nil }
        return category
    }

    // MARK: - Editing the plan

    @ViewBuilder
    private func categoryMenu(_ row: PlanRow, _ category: BudgetCategoryModel) -> some View {
        if row.shortfall > 0 {
            Button("Assign \(budget.money(row.shortfall)) to Cover") { cover(category) }
        }
        Button("Show Details") {
            selection = row.id
            showsInspector = true
        }
        // The app's own categories — one per card — follow the accounts, not the menu.
        if !CategoryWriter.isManaged(category) {
            Divider()
            Button("Rename…") { edit = .renameCategory(category) }
            Button(category.hidden ? String(localized: "Show") : String(localized: "Hide")) {
                attempt { try CategoryWriter.setHidden(!category.hidden, on: category, in: modelContext) }
            }
            Button("Delete…", role: .destructive) { edit = .deleteCategory(category) }
        }
    }

    @ViewBuilder
    private func groupMenu(_ group: CategoryGroup) -> some View {
        if !CategoryWriter.isManaged(group) {
            // A starter group keeps its name and stays on the plan, so it can only be hidden.
            let isStarter = CategoryWriter.starter(group) != nil
            Button("Add a category…") { edit = .addCategory(group) }
            Divider()
            if !isStarter {
                Button("Rename…") { edit = .renameGroup(group) }
            }
            Button(group.hidden ? String(localized: "Show Group") : String(localized: "Hide Group")) {
                attempt { try CategoryWriter.setHidden(!group.hidden, on: group, in: modelContext) }
            }
            if !isStarter {
                Button("Delete Group…", role: .destructive) { edit = .deleteGroup(group) }
            }
        }
    }

    /// A category dropped on a category takes its place, in that category's group; dropped on a
    /// group, it goes to the top of it. A group dropped on a group takes that group's place.
    private func drop(_ items: [String], onto target: PlanRow) {
        guard let dragged = items.first.flatMap(PlanDrag.init) else { return }
        let groups = rows.compactMap(\.group)
        switch dragged {
        case let .category(id):
            guard let category = rows.lazy.flatMap(\.children).first(where: { $0.id == id })?.category else { return }
            if let targetGroup = target.group {
                attempt { try CategoryWriter.move(category, to: targetGroup, at: 0, in: modelContext) }
            } else if let targetCategory = target.category, let targetGroup = targetCategory.group {
                let index = CategoryWriter.editorOrder(targetGroup)
                    .filter { $0.identifier != category.identifier }
                    .firstIndex { $0.identifier == targetCategory.identifier } ?? 0
                attempt { try CategoryWriter.move(category, to: targetGroup, at: index, in: modelContext) }
            }
        case let .group(id):
            guard let moving = groups.first(where: { $0.identifier == id }),
                  let targetGroup = target.group ?? target.category?.group,
                  targetGroup.identifier != id
            else { return }
            var order = self.groups.filter { $0.identifier != id }
            let at = order.firstIndex { $0.identifier == targetGroup.identifier } ?? order.count
            order.insert(moving, at: at)
            attempt { try CategoryWriter.reorder(order, in: modelContext) }
        }
    }

    @State private var refusal: String?

    /// Runs an edit, shows the reason if the plan will not have it, and recomputes either way.
    private func attempt(_ body: () throws -> Void) {
        do {
            try body()
            budget.refresh(in: modelContext)
        } catch {
            refusal = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Acting

    /// What is saved is the change from what was on screen, so an edit from another device that
    /// lands while this one is typed is added to, not undone.
    private func assign(_ amount: MinorUnits, shown: MinorUnits, to category: BudgetCategoryModel) {
        try? AssignmentWriter.setAssigned(
            amount, shown: shown, category: category, month: budget.visibleMonth, in: modelContext
        )
        budget.refresh(in: modelContext)
    }

    /// Assigns exactly the shortfall: an overspent category lands on zero, and one short of what is
    /// still to come this month holds exactly enough for it. Ready to Assign may go negative:
    /// refusing would hide the overspend rather than fix it.
    private func cover(_ category: BudgetCategoryModel) {
        let amount = budget.shortfall(of: category)
        guard amount > 0 else { return }
        try? AssignmentWriter.adjustAssigned(by: amount, category: category, month: budget.visibleMonth, in: modelContext)
        budget.refresh(in: modelContext)
    }

    private func step(by months: Int) {
        budget.visibleMonth = budget.visibleMonth.adding(months: months)
        budget.refresh(in: modelContext)
    }
}

/// Assigned, typed into its cell. Saved on Return or when the field is left.
private struct AssignedField: View {
    let assigned: MinorUnits
    let currency: Currency
    let commit: (MinorUnits) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("0.00", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($isFocused)
            .onAppear { text = shown }
            // The figure moved underneath — a recompute, or another device. Not while typing.
            .onChange(of: assigned) { _, _ in if !isFocused { text = shown } }
            .onSubmit(save)
            .onChange(of: isFocused) { _, focused in if !focused { save() } }
            .accessibilityIdentifier("assigned-field")
    }

    private var shown: String {
        assigned == 0 ? "" : Money(minorUnits: assigned, currency: currency).formatted(showCurrencySymbol: false)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let amount = trimmed.isEmpty ? 0 : Money.parse(trimmed, currency: currency)?.minorUnits
        guard let amount else {
            // Not a number: put back what was there rather than guess.
            text = shown
            return
        }
        if amount != assigned { commit(amount) }
    }
}

/// Available, in the colour of what it means, as YNAB draws it.
private struct AvailablePill: View {
    let amount: String
    let status: CategoryStatus
    let shortfall: MinorUnits

    @Environment(BudgetModel.self) private var budget

    var body: some View {
        Text(amount)
            .monospacedDigit()
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(status.color.opacity(status == .empty ? 0.12 : 0.18), in: Capsule())
            .foregroundStyle(status.color)
            .help(help)
    }

    private var help: String {
        switch status {
        case let .underfunded(needed): String(localized: "\(budget.money(needed)) more needed")
        case .overspent: String(localized: "Overspent. Next month pays for it unless you cover it.")
        case .creditOverspent: String(localized: "Card spending nothing covered. It is now debt.")
        case .funded, .empty: ""
        }
    }
}

/// What is being dragged about the Plan, carried as text: the table moves strings between rows.
private enum PlanDrag {
    case category(UUID)
    case group(UUID)

    init?(_ text: String) {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "embers-category": self = .category(id)
        case "embers-group": self = .group(id)
        default: return nil
        }
    }

    var text: String {
        switch self {
        case let .category(id): "embers-category:\(id.uuidString)"
        case let .group(id): "embers-group:\(id.uuidString)"
        }
    }
}
