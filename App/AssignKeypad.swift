import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

/// A category's Assigned figure, drawn as something to tap.
///
/// Shown as plain text it was not recognised as editable by anyone who tried the app: the figure
/// had to be found on a second screen, tapped, typed and then "Set". A field on the Plan itself,
/// shaped like one, says what it is.
struct AssignedField: View {
    let amount: String
    let isEditing: Bool

    var body: some View {
        Text(amount)
            .font(.callout.weight(.medium))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isEditing ? Flame.ember.opacity(0.15) : Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isEditing ? Flame.ember : Color.secondary.opacity(0.25), lineWidth: isEditing ? 1.5 : 1)
            )
            .foregroundStyle(isEditing ? Flame.ember : .primary)
    }
}

/// One category's Assigned figure being typed: what it opened on, and what has been typed since.
struct AssignSession: Equatable {
    let category: BudgetCategoryModel
    let month: YearMonth
    /// What the person saw when they started. What is saved is the change from this, so an edit
    /// from another device that lands while they type is added to, not undone.
    let shown: MinorUnits
    var calculator: AssignmentCalculator

    init(category: BudgetCategoryModel, month: YearMonth, shown: MinorUnits, currency: Currency) {
        self.category = category
        self.month = month
        self.shown = shown
        calculator = AssignmentCalculator(startingAt: shown, currency: currency)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.category.persistentModelID == rhs.category.persistentModelID
            && lhs.month == rhs.month && lhs.calculator == rhs.calculator
    }

    /// Saves what was typed. Nothing is written when it comes to what was there.
    @MainActor
    func commit(in context: ModelContext, budget: BudgetModel) {
        // Deleted while the keypad was up — from the plan editor, or merged away by a sync.
        guard !category.isDeleted, category.modelContext != nil else { return }
        guard let amount = calculator.result, amount != shown else { return }
        try? AssignmentWriter.setAssigned(amount, shown: shown, category: category, month: month, in: context)
        budget.refresh(in: context)
    }
}

/// The keypad for assigning, with + − × ÷ so a sum is worked out where it is used.
struct AssignKeypad: View {
    @Binding var session: AssignSession
    let onDone: () -> Void
    let onCancel: () -> Void

    @Environment(BudgetModel.self) private var budget

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        VStack(spacing: 10) {
            header
            LazyVGrid(columns: columns, spacing: 8) {
                digit("7"); digit("8"); digit("9"); op(.divide)
                digit("4"); digit("5"); digit("6"); op(.multiply)
                digit("1"); digit("2"); digit("3"); op(.subtract)
                decimalKey; digit("0"); deleteKey; op(.add)
            }
            HStack(spacing: 8) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("assign-cancel")

                Button(action: onDone) {
                    Label("Assign", systemImage: "checkmark")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Flame.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(session.calculator.result == nil)
                .opacity(session.calculator.result == nil ? 0.5 : 1)
                .accessibilityIdentifier("assign-done")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
        // A keypad reads 1-2-3 from the left in every language, as the phone's own does.
        .environment(\.layoutDirection, .leftToRight)
    }

    /// The category, the sum as typed, what it comes to, and what Ready to Assign will be.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.category.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let after = readyToAssignAfter {
                    Text("Ready to Assign: \(budget.money(after))")
                        .font(.caption)
                        .foregroundStyle(after < 0 ? Flame.outflow : .secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: displayedSum)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(session.calculator.isShowingStart ? .secondary : .primary)
                    .accessibilityIdentifier("assign-expression")
                if session.calculator.hasOperator {
                    Text(verbatim: "= " + (session.calculator.result.map(budget.money) ?? "—"))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("assign-result")
                }
            }
        }
        // Read in the reader's direction, unlike the keys.
        .environment(\.layoutDirection, Locale.display.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }

    /// The sum as typed, with the reader's own decimal mark.
    private var displayedSum: String {
        let text = session.calculator.text
        guard !text.isEmpty else { return budget.money(0) }
        let mark = Locale.display.decimalSeparator ?? "."
        return text.replacingOccurrences(of: ".", with: mark)
            .replacingOccurrences(of: "+", with: " + ")
            .replacingOccurrences(of: "×", with: " × ")
            .replacingOccurrences(of: "÷", with: " ÷ ")
            // Not a leading minus, which belongs to the number.
            .replacingOccurrences(of: "(?<=.)−", with: " − ", options: .regularExpression)
    }

    /// Ready to Assign once this lands, so the person sees what they are giving away as they type.
    private var readyToAssignAfter: MinorUnits? {
        guard let result = session.calculator.result else { return nil }
        return budget.readyToAssign - (result - session.shown)
    }

    private func digit(_ character: Character) -> some View {
        key(Text(String(character)), identifier: "assign-key-\(character)") {
            session.calculator.append(digit: character)
        }
    }

    private func op(_ op: AssignmentCalculator.Operator) -> some View {
        key(Text(String(op.rawValue)), identifier: "assign-key-\(op)", tint: Flame.ember) {
            session.calculator.append(op)
        }
    }

    private var decimalKey: some View {
        key(Text(verbatim: Locale.display.decimalSeparator ?? "."), identifier: "assign-key-decimal") {
            session.calculator.appendDecimalPoint()
        }
        .disabled(session.calculator.currency.minorUnitDigits == 0)
    }

    private var deleteKey: some View {
        key(Text(Image(systemName: "delete.backward")), identifier: "assign-key-delete") {
            session.calculator.deleteLast()
        }
        .accessibilityLabel("Delete")
    }

    private func key(_ label: Text, identifier: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.map { $0.opacity(0.15) } ?? Color.secondary.opacity(0.12))
                )
                .foregroundStyle(tint ?? .primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
