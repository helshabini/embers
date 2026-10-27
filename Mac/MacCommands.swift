import EmbersCore
import SwiftUI

/// What the menu bar can ask of the window. Published by `MacRootView` as a focused value, so the
/// commands act on the window rather than reaching into it.
struct WindowActions {
    let show: (SidebarItem) -> Void
    let newTransaction: () -> Void
    let stepMonth: (Int) -> Void
    let thisMonth: () -> Void
}

extension FocusedValues {
    @Entry var windowActions: WindowActions?
}

struct EmbersCommands: Commands {
    @FocusedValue(\.windowActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Transaction") { actions?.newTransaction() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions == nil)
        }

        CommandMenu("Go") {
            Group {
                Button("Plan") { actions?.show(.plan) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("All Transactions") { actions?.show(.transactions) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Reports") { actions?.show(.reports) }
                    .keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Previous Month") { actions?.stepMonth(-1) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Next Month") { actions?.stepMonth(1) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("This Month") { actions?.thisMonth() }
                    .keyboardShortcut("t", modifiers: .command)
            }
            .disabled(actions == nil)
        }
    }
}
