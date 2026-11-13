import XCTest

/// Reported: tapping a reminder while Embers is closed opens it, and it crashes on the way up.
///
/// A reminder is local, but iOS launches the app for a tap on one exactly as for a push, so the test
/// has one delivered with `xcrun simctl push` while the app is closed — the runner cannot send it —
/// and taps it from the lock screen. Run with `scripts/notification-launch-test.sh`, which sends it.
final class NotificationLaunchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTappingAReminderOpensTheApp() throws {
        // Nothing arrives without the script, so the whole suite skips this rather than wait.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["EMBERS_SENDS_NOTIFICATIONS"] == "1",
            "run through scripts/notification-launch-test.sh, which sends the notification"
        )
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launchArguments += ["-skip-splash", "-reset-ui-state", "-no-cloud-sync"]
        app.launch()

        // A new plan's question comes first in an empty store.
        let currency = app.buttons["plan-currency-continue"]
        if currency.waitForExistence(timeout: 5) { currency.tap() }

        // Reminders on, so iOS will show what is sent.
        app.navigationBars.buttons["open-more"].firstMatch.tap()
        app.buttons["Reminders"].firstMatch.tap()
        let turnOn = app.buttons["turn-on-reminders"]
        if turnOn.waitForExistence(timeout: 5) {
            turnOn.tap()
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 5) { allow.tap() }
        }

        // Closed, and the screen locked, so the tap is the launch.
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        // The script sends one every few seconds throughout; the next lands with the app closed.
        let delivered = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Rent is due")).firstMatch
        XCTAssertTrue(delivered.waitForExistence(timeout: 60), "the reminder should arrive")
        delivered.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "the tap should open Embers")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "Embers should open, not crash")
        sleep(5)
        XCTAssertEqual(app.state, .runningForeground, "Embers should still be running")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "opened-from-reminder"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
