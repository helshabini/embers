import XCTest

/// Reported: in All Transactions, with the inspector open, the window cut off both the sidebar and
/// the inspector. The register's header would not shrink — a segmented control, a row of balances —
/// so the three panes asked for more width together than the window had, and the split view
/// overflowed it on both sides. It did so at the window's default size.
@MainActor
final class MacWindowLayoutUITests: XCTestCase {
    func testThePanesFitTheDefaultWindow() {
        checkThePanesFit(launchArguments: [], name: "default")
    }

    /// At the window's minimum width. A drag on its edge does not resize it under test, so the app
    /// sizes it when asked (`-narrowest-window`).
    func testThePanesFitTheNarrowestWindow() {
        checkThePanesFit(launchArguments: ["-narrowest-window"], name: "narrowest")
    }

    private func checkThePanesFit(launchArguments: [String], name: String) {
        let app = XCUIApplication()
        app.launchArguments += ["-reset-ui-state", "-no-cloud-sync", "-no-reminders"] + launchArguments
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30))
        let sidebar = app.outlines["sidebar"]
        let plan = sidebar.descendants(matching: .any).matching(identifier: "sidebar-plan").firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 30))

        sidebar.descendants(matching: .any).matching(identifier: "sidebar-transactions").firstMatch.click()
        // A new entry opens the inspector, as in the report.
        app.buttons["add-transaction"].firstMatch.click()
        let save = app.buttons["save-transaction"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "the inspector should open")
        sleep(1)

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "\(name)-all-transactions"
        attachment.lifetime = .keepAlways
        add(attachment)

        let bounds = window.frame
        if name == "narrowest" { XCTAssertLessThan(bounds.width, 1_000, "the window should be at its narrowest") }
        XCTAssertGreaterThanOrEqual(plan.frame.minX, bounds.minX, "the sidebar should not be cut off on the left")
        XCTAssertLessThanOrEqual(save.frame.maxX, bounds.maxX + 1, "the inspector should not be cut off on the right")
    }
}
