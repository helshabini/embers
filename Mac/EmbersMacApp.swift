import AppKit
import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

@main
struct EmbersMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var store = StoreLoader.shared
    @State private var cloud = CloudSync()
    /// Held here rather than by the window, so the Settings window reads the same figures.
    @State private var budget = BudgetModel()
    @AppStorage("appearance") private var appearance = Appearance.system

    init() {
        RememberedUIState.resetIfAsked()
    }

    var body: some Scene {
        // One window, not a group. Each window would hold its own `BudgetModel` and run its own
        // launch catch-up, and two of those racing over one store is the double write that
        // docs/data-model/syncing.md exists to prevent.
        Window("Embers", id: "main") {
            Group {
                switch store.state {
                case .loading:
                    // No splash on the Mac: a window that animates before it can be used is a
                    // phone's idea of launching. The store opens in well under a second here.
                    Color.clear.task { store.load() }
                case let .ready(container):
                    MacRootView(budget: budget)
                        .modelContainer(container)
                        .environment(cloud)
                case let .failed(message):
                    StoreFailureView(message: message) { store.load() }
                }
            }
            .frame(minWidth: 900, minHeight: 560)
            .appearanceApplied(appearance)
            // Digits 0–9 in every language; see `Locale.display`.
            .environment(\.locale, .display)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { EmbersCommands() }

        Settings {
            // Opened before the window has finished opening the store, it waits for it.
            if case let .ready(container) = store.state {
                MacSettingsView()
                    .modelContainer(container)
                    .environment(cloud)
                    .environment(budget)
                    .appearanceApplied(appearance)
                    .environment(\.locale, .display)
            } else {
                ProgressView().frame(width: 560, height: 520)
            }
        }
    }
}

/// Gives the notification centre its delegate as the app launches — before the window exists,
/// which a button pressed on a notification while the app was closed does not wait for.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Here, not only in `StoreLoader.load()`: that waits on the window, and one launch from
        // Xcode never got as far as a window, so the push sat idle for ten minutes.
        MainActor.assumeIsolated { CloudKitSchema.runIfRequested() }
        #endif
        MainActor.assumeIsolated { ReminderScheduler.shared.attach() }
    }

    /// The window is the app: closing it is quitting, as it is for any single-window Mac app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
