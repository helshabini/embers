import EmbersData
import SwiftData
import SwiftUI

/// Opens the store.
///
/// The store syncs through the iCloud private database, so every device signed into the same Apple
/// ID holds the same plan. With no iCloud account the same store simply stays on the device; SwiftData
/// starts mirroring it whenever an account appears. What has to wait for the plan to arrive is
/// `CloudSync`'s business.
@MainActor
@Observable
final class StoreLoader {
    static let shared = StoreLoader()

    enum State {
        case loading
        case ready(ModelContainer)
        case failed(String)
    }

    private(set) var state: State = .loading

    /// Open, or failed to open. The splash gives way to either: waiting on success alone left it
    /// over the failure view for good, so a store that would not open looked like a hung launch.
    var hasSettled: Bool {
        if case .loading = state { return false }
        return true
    }

    func load() {
        if case .ready = state { return }
        // Before anything opens it: once open, iCloud holds the files.
        CloudSync.setAsideLocalCopyIfRequested()
        do {
            state = .ready(try EmbersStore.container(
                cloudKitContainerIdentifier: CloudSync.isEnabled ? CloudSync.containerIdentifier : nil,
                url: CloudSync.storeURL
            ))
        } catch {
            state = .failed(String(describing: error))
        }
    }
}

struct StoreFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Could not open your budget", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}

/// The small preferences that decide what a screen looks like when it opens.
enum RememberedUIState {
    /// Forgets them, only under a launch argument, and only for tests: they share one simulator, so
    /// a test that folds a section away leaves it folded for whichever test runs next, which made
    /// two of them pass or fail depending on the order they happened to run in.
    static func resetIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("-reset-ui-state") else { return }
        for key in ["scheduledExpanded", "appearance"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
