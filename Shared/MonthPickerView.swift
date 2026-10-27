import EmbersCore
import SwiftUI

/// Jumping to a month without tapping an arrow thirty times.
struct MonthPickerView: View {
    let selected: YearMonth
    /// The span the budget actually covers, so the years offered are years that exist.
    let available: ClosedRange<Int>
    let onPick: (YearMonth) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var year: Int

    init(selected: YearMonth, available: ClosedRange<Int>, onPick: @escaping (YearMonth) -> Void) {
        self.selected = selected
        self.available = available
        self.onPick = onPick
        _year = State(initialValue: selected.year)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .padding(20)
                .navigationTitle("Go to month")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium])
        .flameTinted()
        #else
        // A popover on the Mac, which needs no bar of its own: Escape or a click outside closes it.
        content
            .padding(16)
            .frame(width: 300)
            .flameTinted()
        #endif
    }

    private var content: some View {
        VStack(spacing: 20) {
            HStack {
                Button {
                    year -= 1
                } label: {
                    Image(systemName: "chevron.backward").font(.body.weight(.semibold))
                }
                .disabled(year <= available.lowerBound)

                Spacer()
                Text(String(year))
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()

                Button {
                    year += 1
                } label: {
                    Image(systemName: "chevron.forward").font(.body.weight(.semibold))
                }
                .disabled(year >= available.upperBound)
            }
            .padding(.horizontal, 8)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(1...12, id: \.self) { month in
                    monthButton(YearMonth(year: year, month: month))
                }
            }

            Button {
                onPick(.current())
                dismiss()
            } label: {
                Label("This month", systemImage: "calendar")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .background(Flame.tintedFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityIdentifier("jump-to-this-month")

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func monthButton(_ month: YearMonth) -> some View {
        let isSelected = month == selected
        let isThisMonth = month == YearMonth.current()
        Button {
            onPick(month)
            dismiss()
        } label: {
            Text(month.shortMonthName)
                .font(.callout.weight(isSelected ? .bold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(Flame.gradient) : AnyShapeStyle(Flame.tintedFill))
                )
                .foregroundStyle(isSelected ? .white : .primary)
                .overlay(alignment: .bottom) {
                    // A quiet mark for today's month, so "where am I" is answerable at a glance.
                    if isThisMonth, !isSelected {
                        Circle()
                            .fill(Flame.ember)
                            .frame(width: 4, height: 4)
                            .padding(.bottom, 5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("month-option")
    }
}

/// The month bar at the top of the Plan: back, the month itself, forward.
///
/// One control rather than three separate toolbar items. As three, the month was placed by SwiftUI
/// against whatever the leading and trailing items happened to measure, and some months sat off
/// centre while others did not.
struct MonthNavigator: View {
    let month: YearMonth
    let onStep: (Int) -> Void
    let onTapMonth: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button { onStep(-1) } label: {
                Image(systemName: "chevron.backward")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("previous-month")

            Button(action: onTapMonth) {
                Text(month.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .frame(height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("month-name")

            Button { onStep(1) } label: {
                Image(systemName: "chevron.forward")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("next-month")
        }
    }
}
