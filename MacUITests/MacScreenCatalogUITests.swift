import XCTest

/// Walks every screen of the Mac app, saving a screenshot of each, without changing anything.
///
/// The Mac counterpart of `ScreenCatalogUITests`, and for now the only way to look at the window:
/// the shell that builds it has no screen-recording permission, while the test runner does.
/// Runs against whatever is in the app's `Embers-UITests.store`; seed it first
/// (docs/testing/ui-tests.md).
@MainActor
final class MacScreenCatalogUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
    }

    func testCatalogueEveryScreen() {
        app = XCUIApplication()
        app.launchArguments += ["-reset-ui-state", "-no-cloud-sync", "-no-reminders"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "the window should open")
        XCTAssertTrue(sidebar("sidebar-plan").waitForExistence(timeout: 30), "the sidebar should load")
        shot("01-plan")
        // By position: the second category of the first group.
        let plan = app.outlines["plan-table"].exists ? app.outlines["plan-table"] : app.tables.firstMatch
        if plan.waitForExistence(timeout: 5) {
            plan.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.1)).click()
            sleep(1)
            shot("02-plan-category-selected")
        }
        if tap(app.descendants(matching: .any).matching(identifier: "month-name").firstMatch) {
            shot("03-month-picker")
            app.typeKey(.escape, modifierFlags: [])
        }

        if tap(sidebar("sidebar-transactions")) {
            shot("10-all-transactions")
            if tap(app.descendants(matching: .any).matching(identifier: "scheduled-header").firstMatch) {
                shot("11-all-transactions-scheduled")
                tap(app.descendants(matching: .any).matching(identifier: "scheduled-header").firstMatch)
            }
        }
        if tap(sidebar("sidebar-reports")) { shot("50-reports") }
        if tap(sidebar("sidebar-budget-check")) { shot("60-budget-check") }
        if tap(sidebar("sidebar-account")) {
            shot("40-register")
            // The first row, by position.
            let table = app.tables.firstMatch
            if table.waitForExistence(timeout: 3) {
                table.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.04)).click()
                sleep(1)
                shot("41-register-editing")
            }
            if tap(app.buttons["add-transaction"].firstMatch) {
                let amount = app.textFields["amount-field"].firstMatch
                if amount.waitForExistence(timeout: 3) {
                    amount.click()
                    amount.typeText("1250")
                    sleep(1)
                }
                shot("42-new-transaction")
                if tap(app.buttons["currency-picker"].firstMatch) {
                    shot("43-currency-list")
                    app.typeKey(.escape, modifierFlags: [])
                }
                if tap(app.checkBoxes["transfer-toggle"].firstMatch) || tap(app.switches["transfer-toggle"].firstMatch) {
                    shot("44-new-transfer")
                }
                // Not saved: the catalogue changes nothing.
                app.typeKey(.escape, modifierFlags: [])
            }
        }

        // The Settings window, tab by tab.
        app.typeKey(",", modifierFlags: .command)
        if app.toolbars.buttons["General"].waitForExistence(timeout: 5) {
            for (tab, name) in [
                ("General", "70-settings-general"),
                ("Currency & FX", "71-settings-fx"),
                ("Reminders", "72-settings-reminders"),
                ("Import", "73-settings-import"),
                ("Backups", "74-settings-backups"),
            ] {
                app.toolbars.buttons[tab].click()
                sleep(1)
                shot(name, of: app.windows.firstMatch)
            }
            app.typeKey("w", modifierFlags: .command)
        }
    }

    /// The App Store set: the main screens only, at whatever size the window was left. Size it to
    /// 1440 × 900 points first, which comes out at the listing's 2880 × 1800. Kept apart from the
    /// catalogue, whose month-picker step lost the window on 31 Oct 2026, and sheets come last.
    ///
    /// No `-reset-ui-state`, so the appearance comes from the stored `appearance` default: write
    /// `light` or `dark` into the container's preferences before running. Passing it as a launch
    /// argument instead (`-appearance dark`) left the test with no window at all.
    func testAppStoreScreens() {
        app = XCUIApplication()
        app.launchArguments += ["-no-cloud-sync", "-no-reminders"]
        app.launch()
        XCTAssertTrue(sidebar("sidebar-plan").waitForExistence(timeout: 30), "the sidebar should load")
        sleep(2)
        shot("store-01-plan")
        if tap(sidebar("sidebar-transactions")) { shot("store-02-transactions") }
        if tap(sidebar("sidebar-account")) { shot("store-03-register") }
        if tap(sidebar("sidebar-reports")) { sleep(1); shot("store-04-reports") }
        if tap(sidebar("sidebar-budget-check")) { shot("store-05-budget-check") }
        if tap(sidebar("sidebar-account")), tap(app.buttons["add-transaction"].firstMatch) {
            let amount = app.textFields["amount-field"].firstMatch
            if amount.waitForExistence(timeout: 3) {
                amount.click()
                amount.typeText("1250")
                sleep(1)
            }
            shot("store-06-new-transaction")
        }
    }

    /// The notice a new Mac shows while its budget comes down from iCloud, which a test cannot
    /// stage for real.
    func testFirstDownloadNotice() {
        app = XCUIApplication()
        app.launchArguments += ["-reset-ui-state", "-no-cloud-sync", "-no-reminders", "-simulate-first-download"]
        app.launch()
        let notice = app.descendants(matching: .any).matching(identifier: "first-download-notice").firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 30), "the notice should say the budget is arriving")
        sleep(3)
        shot("80-first-download")
    }

    // MARK: - Moving about

    /// Looked for inside the sidebar only. Searching the whole window walks every row of whatever
    /// table is showing, and a thousand-row register made that time out.
    private func sidebar(_ identifier: String) -> XCUIElement {
        app.outlines["sidebar"].descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    private func tap(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 3) else { return false }
        element.click()
        sleep(1)
        return true
    }

    private func shot(_ name: String, of window: XCUIElement? = nil) {
        let attachment = XCTAttachment(screenshot: (window ?? app.windows.firstMatch).screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
