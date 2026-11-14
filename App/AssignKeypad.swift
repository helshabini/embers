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
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 6)
            // A fixed height: sized to its text, a large figure shrunk to fit made a smaller box.
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .trailing)
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

    var body: some View {
        VStack(spacing: 10) {
            header
            // Not a lazy grid: one builds its rows as they arrive, and sliding up it drew them
            // squashed over one another for the first frames.
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow { digit("7"); digit("8"); digit("9"); op(.divide) }
                GridRow { digit("4"); digit("5"); digit("6"); op(.multiply) }
                GridRow { digit("1"); digit("2"); digit("3"); op(.subtract) }
                GridRow { decimalKey; digit("0"); deleteKey; op(.add) }
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assign-keypad")
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

/// The keypad over the foot of a list, and room under the list to scroll any row clear of it.
///
/// Laid over the list rather than set into its safe area. As a safe-area inset its height was
/// animated along with it: near the end of the plan, the row just scrolled above it was pulled
/// back under as the inset passed through smaller heights, and the keys arrived in pieces. Here the
/// list's room is a fixed padding, set at once, and the keypad slides on its own.
struct AssignKeypadHost: ViewModifier {
    @Binding var session: AssignSession?
    let onDone: () -> Void

    /// Measured once it is up; this is close enough for the first frame.
    @State private var height: CGFloat = 360

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.bottom, session == nil ? 0 : height)
            .overlay(alignment: .bottom) {
                if let opened = session {
                    // Falls back to the session it opened on: while it slides away the session is
                    // already gone, and a recompute landing then draws it once more.
                    AssignKeypad(
                        session: Binding(get: { session ?? opened }, set: { session = $0 }),
                        onDone: onDone,
                        onCancel: { withAnimation(.snappy) { session = nil } }
                    )
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                    // Slides in solid, as the keyboard does; faded in too, the rows showed through
                    // it. Faded on the way out: it leaves behind a floating tab bar, and moved alone
                    // its Assign button showed through below the tabs on the way down.
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
                }
            }
    }
}

extension View {
    func assignKeypad(_ session: Binding<AssignSession?>, onDone: @escaping () -> Void) -> some View {
        modifier(AssignKeypadHost(session: session, onDone: onDone))
    }
}
