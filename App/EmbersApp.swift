import EmbersCore
import EmbersData
import SwiftData
import SwiftUI

@main
struct EmbersApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Shared with the reminders: a button pressed on one can wake the app with no window, and
    /// must open the same store the window would rather than a second copy of it.
    @State private var store = StoreLoader.shared
    @State private var cloud = CloudSync()

    // UI tests drive the screens, not the launch animation; one test covers the splash itself and
    // the rest skip it rather than racing a full-screen overlay for every first tap.
    @State private var hasShownSplash = ProcessInfo.processInfo.arguments.contains("-skip-splash")
    @AppStorage("appearance") private var appearance = Appearance.system

    private static let holdsSplash = ProcessInfo.processInfo.arguments.contains("-hold-splash")

    init() {
        RememberedUIState.resetIfAsked()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                switch store.state {
                case .loading:
                    // The splash itself stands in while the store opens, rather than a blank colour
                    // that is indistinguishable from the system launch screen.
                    Color(.systemBackground)
                        .ignoresSafeArea()
                        .task { store.load() }
                case let .ready(container):
                    RootView()
                        .modelContainer(container)
                        .environment(cloud)
                case let .failed(message):
                    StoreFailureView(message: message) { store.load() }
                }

                // Sits over the top until the tree has finished catching, so the store can open
                // behind it rather than after it.
                if !hasShownSplash {
                    // `-hold-splash` keeps it up so a test can look at it. Handing over is what the
                    // splash gets wrong when it gets anything wrong, so it is worth being able to
                    // hold it still and assert on it rather than racing the animation.
                    SplashView(isReady: store.hasSettled && !Self.holdsSplash) {
                        withAnimation(.easeOut(duration: 0.35)) { hasShownSplash = true }
                    }
                    .transition(.opacity)
                }
            }
            .appearanceApplied(appearance)
            // Digits 0–9 in every language; see `Locale.display`.
            .environment(\.locale, .display)
        }
    }
}

/// Gives the notification centre its delegate as the app launches — before a scene exists, which
/// a button pressed on a notification while the app was closed does not wait for.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MainActor.assumeIsolated { ReminderScheduler.shared.attach() }
        return true
    }
}
