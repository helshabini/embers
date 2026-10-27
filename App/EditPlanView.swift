import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// Adding, renaming, moving, hiding and removing the categories money gets assigned to.
///
/// Deleting is deliberately hard to reach: a category money has passed through is history, and the
/// figures in every month it appears in depend on it. Hiding takes it off the plan and leaves all of
/// that standing, which is what people almost always mean.
struct EditPlanView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(BudgetModel.self) private var budget
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CategoryGroup.order) private var groups: [CategoryGroup]

    @State private var newGroupName = ""
    @State private var isAddingGroup = false
    @State private var adding: CategoryGroup?
    @State private var newCategoryName = ""
    @State private var renaming: Renaming?
    @State private var refusal: String?
    @State private var confirmingDelete: Deleting?
    @State private var editMode: EditMode = .inactive

    /// One confirmation for both, rather than a second alert stacked on a view that has four.
    private enum Deleting {
        case category(BudgetCategoryModel)
        case group(CategoryGroup)
    }

    private struct Renaming: Identifiable {
        let id: UUID
        let title: String
        var name: String
        let commit: (String) throws -> Void
        /// What the field started with. A starter category is shown translated, so saving it
        /// unchanged must not store the translation as though the person had typed it.
        var original: String = ""
    }

    /// One line of the reordering list: groups and categories in a single run, so a category can be
    /// dragged past a group's heading into the next group. Sections cannot do that — a move never
    /// leaves the `ForEach` it started in.
    private enum Line: Identifiable {
        case group(CategoryGroup)
        case category(BudgetCategoryModel)

        var id: UUID {
            switch self {
            case let .group(group): group.identifier
            case let .category(category): category.identifier
            }
        }
    }

    private var isReordering: Bool { editMode.isEditing }

    var body: some View {
        NavigationStack {
            Group {
                if isReordering { reorderingList } else { editingList }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Edit Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isReordering ? String(localized: "Done Moving") : String(localized: "Reorder")) {
                        withAnimation { editMode = isReordering ? .inactive : .active }
                    }
                    .accessibilityIdentifier("reorder-plan")
                }
                // In the bar rather than at the foot of the list: with nine groups on the plan, a
                // row at the bottom is a scroll away from everything.
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newGroupName = ""
                        isAddingGroup = true
                    } label: {
                        Label("Add Group", systemImage: "plus")
                    }
                    .accessibilityIdentifier("add-group")
                    .disabled(isReordering)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Add a group",
                isPresented: $isAddingGroup,
                actions: {
                    TextField("Name", text: $newGroupName)
                        .accessibilityIdentifier("new-group-name")
                    Button("Cancel", role: .cancel) {}
                    Button("Add") { addGroup() }
                },
                message: { Text("Groups hold categories — Kids, Side Business, Pets.") }
            )
            .alert("Can't do that", isPresented: .constant(refusal != nil)) {
                Button("OK") { refusal = nil }
            } message: {
                Text(refusal ?? "")
            }
            .alert(
                "Add a category",
                isPresented: .constant(adding != nil),
                actions: {
                    TextField("Name", text: $newCategoryName)
                    Button("Cancel", role: .cancel) { adding = nil }
                    Button("Add") { addCategory() }
                },
                message: { Text(adding.map { String(localized: "In \($0.displayName).") } ?? "") }
            )
            .alert(
                renaming?.title ?? String(localized: "Rename"),
                isPresented: .constant(renaming != nil),
                actions: {
                    TextField("Name", text: Binding(
                        get: { renaming?.name ?? "" },
                        set: { renaming?.name = $0 }
                    ))
                    Button("Cancel", role: .cancel) { renaming = nil }
                    Button("Rename") { commitRename() }
                }
            )
            .alert(
                confirmingDelete.map(deleteTitle) ?? String(localized: "Delete?"),
                isPresented: .constant(confirmingDelete != nil),
                actions: {
                    Button("Cancel", role: .cancel) { confirmingDelete = nil }
                    Button("Delete", role: .destructive) { confirmDelete() }
                },
                message: { Text("Nothing has been assigned or spent here, so nothing is lost.") }
            )
        }
        .flameTinted()
    }

    private var editingList: some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(categories(in: group)) { category in
                        row(category)
                    }
                    if !CategoryWriter.isManaged(group) {
                        Button {
                            newCategoryName = ""
                            adding = group
                        } label: {
                            Label("Add a category", systemImage: "plus.circle")
                                .font(.callout)
                        }
                        .accessibilityIdentifier("add-category")
                    }
                } header: {
                    header(group)
                } footer: {
                    if CategoryWriter.isManaged(group) {
                        Text(managedFooter(group))
                    }
                }
            }
        }
    }

    // MARK: - Reordering

    /// Only what can move is listed: the app's own groups keep their places, and nothing is
    /// dragged into them.
    private var lines: [Line] {
        groups.filter { !CategoryWriter.isManaged($0) }.flatMap { group in
            [Line.group(group)] + CategoryWriter.editorOrder(group).map(Line.category)
        }
    }

    private var reorderingList: some View {
        List {
            Section {
                ForEach(lines) { line in
                    switch line {
                    case let .group(group):
                        Text(group.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Flame.deep)
                            .accessibilityIdentifier("move-group")
                    case let .category(category):
                        Text(category.displayName)
                            .foregroundStyle(category.hidden ? .secondary : .primary)
                            .padding(.leading, 16)
                            .accessibilityIdentifier("move-category")
                    }
                }
                .onMove(perform: move)
            } footer: {
                Text("Drag a category to reorder it, or past a group's name to move it there. Dragging a group takes its categories with it.")
            }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var moved = lines
        guard let from = source.first else { return }
        let line = moved[from]
        moved.move(fromOffsets: source, toOffset: destination)
        guard let landed = moved.firstIndex(where: { $0.id == line.id }) else { return }

        switch line {
        case .group:
            // The categories stay with their own groups wherever their rows ended up; only the
            // order of the groups' names is read back.
            let order = moved.compactMap { if case let .group(group) = $0 { group } else { nil } }
            attempt { try CategoryWriter.reorder(order, in: modelContext) }
        case let .category(category):
            // Its group is the nearest one named above where it was dropped. Dropped above every
            // group, it goes to the top of the first.
            let above = moved[..<landed].lastIndex { if case .group = $0 { true } else { false } }
            let headerIndex = above ?? moved.firstIndex { if case .group = $0 { true } else { false } }
            guard let headerIndex, case let .group(group) = moved[headerIndex] else { return }
            let index = above == nil ? 0 : landed - headerIndex - 1
            attempt { try CategoryWriter.move(category, to: group, at: index, in: modelContext) }
        }
    }

    @ViewBuilder
    private func row(_ category: BudgetCategoryModel) -> some View {
        HStack {
            Text(category.displayName)
                .foregroundStyle(category.hidden ? .secondary : .primary)
            if category.hidden {
                // One key per thing hidden: a category and a group differ in gender in some
                // languages, and the badge agrees with what it sits on.
                Text(String(localized: "category.hidden", defaultValue: "Hidden"))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Flame.tintedFill, in: Capsule())
                    .foregroundStyle(Flame.deep)
            }
            Spacer()
        }
        .accessibilityIdentifier("edit-category")
        .swipeActions(edge: .trailing) {
            if !CategoryWriter.isManaged(category) {
                // Icons alone: three titled buttons took the whole row, so the category being
                // edited was swiped out of sight. The titles stay as accessibility labels.
                Button(role: .destructive) { askToDelete(category) } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete")
                Button { toggleHidden(category) } label: {
                    Image(systemName: category.hidden ? "eye" : "eye.slash")
                }
                .accessibilityLabel(category.hidden ? String(localized: "Show") : String(localized: "Hide"))
                .tint(.orange)
                Button { startRenaming(category) } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Rename")
                .tint(Flame.ember)
            }
        }
    }

    @ViewBuilder
    private func header(_ group: CategoryGroup) -> some View {
        HStack {
            Text(group.displayName)
            if let starter = CategoryWriter.starter(group) {
                GroupPurposeButton(group: group.displayName, purpose: starter.purpose)
            }
            if group.hidden {
                Text(String(localized: "group.hidden", defaultValue: "Hidden"))
                    .font(.caption2.weight(.medium))
                    .textCase(nil)
            }
            Spacer()
            if !CategoryWriter.isManaged(group) {
                // A header cannot be swiped, so the group's edits sit behind one button.
                // A starter group keeps its name and stays on the plan, so it can only be hidden.
                let isStarter = CategoryWriter.starter(group) != nil
                Menu {
                    if !isStarter {
                        Button { startRenaming(group) } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                    }
                    Button { toggleHidden(group) } label: {
                        Label(
                            group.hidden ? String(localized: "Show Group") : String(localized: "Hide Group"),
                            systemImage: group.hidden ? "eye" : "eye.slash"
                        )
                    }
                    if !isStarter {
                        Button(role: .destructive) { askToDelete(group) } label: {
                            Label("Delete Group", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                }
                .accessibilityLabel("Edit \(group.displayName)")
                .accessibilityIdentifier("edit-group")
            }
        }
    }

    private func managedFooter(_ group: CategoryGroup) -> String {
        switch group.name {
        case CategoryWriter.creditCardGroupName:
            String(localized: "One for each open credit card, kept in step with your accounts. Close a card and it moves to Hidden; its figures stay.")
        case CategoryWriter.hiddenGroupName:
            String(localized: "Categories taken off the plan. Everything they hold is still counted in the months it happened.")
        default:
            String(localized: "The app keeps this one.")
        }
    }

    private func categories(in group: CategoryGroup) -> [BudgetCategoryModel] {
        CategoryWriter.editorOrder(group)
    }

    // MARK: - Doing it

    private func addGroup() {
        attempt { try CategoryWriter.addGroup(named: newGroupName, in: modelContext) }
        newGroupName = ""
        isAddingGroup = false
    }

    private func addCategory() {
        guard let group = adding else { return }
        attempt { try CategoryWriter.add(newCategoryName, to: group, in: modelContext) }
        adding = nil
    }

    private func startRenaming(_ category: BudgetCategoryModel) {
        renaming = Renaming(
            id: category.identifier,
            title: String(localized: "Rename category"),
            name: category.displayName,
            commit: { try CategoryWriter.rename(category, to: $0, in: modelContext) },
            original: category.displayName
        )
    }

    private func startRenaming(_ group: CategoryGroup) {
        renaming = Renaming(
            id: group.identifier,
            title: String(localized: "Rename group"),
            name: group.displayName,
            commit: { try CategoryWriter.rename(group, to: $0, in: modelContext) },
            original: group.displayName
        )
    }

    private func commitRename() {
        guard let renaming else { return }
        guard renaming.name.trimmingCharacters(in: .whitespacesAndNewlines) != renaming.original else {
            self.renaming = nil
            return
        }
        attempt { try renaming.commit(renaming.name) }
        self.renaming = nil
    }

    private func toggleHidden(_ category: BudgetCategoryModel) {
        attempt { try CategoryWriter.setHidden(!category.hidden, on: category, in: modelContext) }
    }

    private func toggleHidden(_ group: CategoryGroup) {
        attempt { try CategoryWriter.setHidden(!group.hidden, on: group, in: modelContext) }
    }

    /// Only offers to delete what really can be; otherwise says why not.
    private func askToDelete(_ category: BudgetCategoryModel) {
        do {
            if let reason = try CategoryWriter.deletionRefusal(for: category, in: modelContext) {
                refusal = reason.errorDescription
                return
            }
            confirmingDelete = .category(category)
        } catch {
            refusal = error.localizedDescription
        }
    }

    /// A group with any history in it is refused whole, with the count, and Hide offered instead.
    private func askToDelete(_ group: CategoryGroup) {
        do {
            if let reason = try CategoryWriter.deletionRefusal(for: group, in: modelContext) {
                refusal = reason.errorDescription
                return
            }
            confirmingDelete = .group(group)
        } catch {
            refusal = error.localizedDescription
        }
    }

    private func deleteTitle(_ deleting: Deleting) -> String {
        switch deleting {
        case .category: String(localized: "Delete this category?")
        case .group: String(localized: "Delete this group and its categories?")
        }
    }

    private func confirmDelete() {
        switch confirmingDelete {
        case let .category(category):
            attempt { try CategoryWriter.delete(category, in: modelContext) }
        case let .group(group):
            attempt { try CategoryWriter.delete(group, in: modelContext) }
        case nil:
            break
        }
        confirmingDelete = nil
    }

    /// Runs an edit, shows the reason if the plan will not have it, and recomputes either way.
    private func attempt(_ body: () throws -> Void) {
        do {
            try body()
            budget.refresh(in: modelContext)
        } catch {
            refusal = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// The (i) beside a starter group, saying what the group is for. Only a description: the person
/// may use the group however they like.
///
/// A popover of its own on each button, rather than one on the screen, so it points at the group
/// it describes.
private struct GroupPurposeButton: View {
    let group: String
    let purpose: String
    @State private var isShowing = false

    var body: some View {
        Button { isShowing = true } label: {
            Image(systemName: "info.circle")
                .font(.footnote)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("About \(group)")
        .accessibilityIdentifier("group-purpose")
        .popover(isPresented: $isShowing) {
            // Its own colour: it sits in a section header, whose grey it would otherwise inherit.
            Text(purpose)
                .font(.callout)
                .foregroundStyle(.primary)
                .textCase(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(idealWidth: 280)
                .padding()
                .presentationCompactAdaptation(.popover)
        }
    }
}
