import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// Something the Plan's menus asked to change, waiting on a name or a confirmation.
enum PlanEdit: Identifiable {
    case addGroup
    case addCategory(CategoryGroup)
    case renameCategory(BudgetCategoryModel)
    case renameGroup(CategoryGroup)
    case deleteCategory(BudgetCategoryModel)
    case deleteGroup(CategoryGroup)

    var id: String {
        switch self {
        case .addGroup: "addGroup"
        case let .addCategory(group): "add-\(group.identifier)"
        case let .renameCategory(category): "rename-\(category.identifier)"
        case let .renameGroup(group): "rename-\(group.identifier)"
        case let .deleteCategory(category): "delete-\(category.identifier)"
        case let .deleteGroup(group): "delete-\(group.identifier)"
        }
    }
}

/// The phone's Edit Plan screen, folded into the Plan itself: the same rules through the same
/// `CategoryWriter`, asked for from a menu instead of a swipe.
///
/// Deleting stays hard to reach, as on the phone: a category money has passed through is history,
/// and the figures in every month it appears in depend on it. The writer refuses, and says why.
struct PlanEditing: ViewModifier {
    @Binding var edit: PlanEdit?

    @Environment(\.modelContext) private var modelContext
    @Environment(BudgetModel.self) private var budget
    @State private var name = ""
    /// What the field started with. A starter category is shown translated, so saving it unchanged
    /// must not store the translation as though the person had typed it.
    @State private var original = ""
    @State private var refusal: String?

    func body(content: Content) -> some View {
        content
            .alert(nameTitle, isPresented: isAskingForName) {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("plan-edit-name")
                Button("Cancel", role: .cancel) { edit = nil }
                Button(isRenaming ? String(localized: "Rename") : String(localized: "Add")) { commitName() }
            } message: {
                Text(nameMessage)
            }
            .alert(deleteTitle, isPresented: isConfirmingDelete) {
                Button("Cancel", role: .cancel) { edit = nil }
                Button("Delete", role: .destructive) { commitDelete() }
            } message: {
                Text("Nothing has been assigned or spent here, so nothing is lost.")
            }
            .alert("Can't do that", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
                Button("OK") { refusal = nil }
            } message: {
                Text(refusal ?? "")
            }
            // Taken from the change: the request decides what the field starts with.
            .onChange(of: edit?.id) { _, _ in begin(edit) }
    }

    // MARK: - Asking

    private func begin(_ edit: PlanEdit?) {
        switch edit {
        case let .renameCategory(category):
            name = category.displayName
            original = category.displayName
        case let .renameGroup(group):
            name = group.displayName
            original = group.displayName
        case let .deleteCategory(category):
            // Only offers to delete what really can be; otherwise says why not.
            if let reason = refusal(deleting: { try CategoryWriter.deletionRefusal(for: category, in: modelContext) }) {
                self.edit = nil
                refusal = reason
            }
        case let .deleteGroup(group):
            // A group with any history in it is refused whole, with the count, and Hide offered instead.
            if let reason = refusal(deleting: { try CategoryWriter.deletionRefusal(for: group, in: modelContext) }) {
                self.edit = nil
                refusal = reason
            }
        case .addGroup, .addCategory, nil:
            name = ""
            original = ""
        }
    }

    private func refusal(deleting check: () throws -> CategoryWriter.Refusal?) -> String? {
        do {
            return try check()?.errorDescription
        } catch {
            return error.localizedDescription
        }
    }

    private var isRenaming: Bool {
        switch edit {
        case .renameCategory, .renameGroup: true
        default: false
        }
    }

    private var isAskingForName: Binding<Bool> {
        Binding(
            get: {
                switch edit {
                case .addGroup, .addCategory, .renameCategory, .renameGroup: true
                default: false
                }
            },
            set: { if !$0 { edit = nil } }
        )
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(
            get: {
                switch edit {
                case .deleteCategory, .deleteGroup: true
                default: false
                }
            },
            set: { if !$0 { edit = nil } }
        )
    }

    private var nameTitle: String {
        switch edit {
        case .addGroup: String(localized: "Add a group")
        case .addCategory: String(localized: "Add a category")
        case .renameCategory: String(localized: "Rename category")
        case .renameGroup: String(localized: "Rename group")
        default: ""
        }
    }

    private var nameMessage: String {
        switch edit {
        case .addGroup: String(localized: "Groups hold categories — Kids, Side Business, Pets.")
        case let .addCategory(group): String(localized: "In \(group.displayName).")
        default: ""
        }
    }

    private var deleteTitle: String {
        switch edit {
        case .deleteGroup: String(localized: "Delete this group and its categories?")
        default: String(localized: "Delete this category?")
        }
    }

    // MARK: - Doing it

    private func commitName() {
        let edit = edit
        self.edit = nil
        switch edit {
        case .addGroup:
            attempt { try CategoryWriter.addGroup(named: name, in: modelContext) }
        case let .addCategory(group):
            attempt { try CategoryWriter.add(name, to: group, in: modelContext) }
        case let .renameCategory(category):
            guard name.trimmingCharacters(in: .whitespacesAndNewlines) != original else { return }
            attempt { try CategoryWriter.rename(category, to: name, in: modelContext) }
        case let .renameGroup(group):
            guard name.trimmingCharacters(in: .whitespacesAndNewlines) != original else { return }
            attempt { try CategoryWriter.rename(group, to: name, in: modelContext) }
        default:
            break
        }
    }

    private func commitDelete() {
        let edit = edit
        self.edit = nil
        switch edit {
        case let .deleteCategory(category):
            attempt { try CategoryWriter.delete(category, in: modelContext) }
        case let .deleteGroup(group):
            attempt { try CategoryWriter.delete(group, in: modelContext) }
        default:
            break
        }
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
