import XCTest

/// Walks every screen and sheet the app has, saving a screenshot of each, without changing anything.
///
/// The review copy for layout work: the desktop design was drawn from these. Unlike the language
/// tours it goes everywhere — sheets, pickers, the screens behind a row — and run on an iPad in
/// landscape it shows what the phone layout does with the room.
///
/// Nothing here asserts much beyond reaching each screen. A step that cannot be reached on this
/// budget (nothing to approve, say) is skipped rather than failed.
@MainActor
final class ScreenCatalogUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
    }

    func testCatalogueEveryScreen() {
        app = XCUIApplication()
        app.launchArguments += ["-skip-splash", "-reset-ui-state", "-no-cloud-sync", "-no-reminders"]
        app.launch()
        // `TEST_RUNNER_PORTRAIT=1` for the App Store: a landscape screenshot comes back on a
        // portrait canvas, half of it black and the right side cut off (an iPad, and an unfolded
        // iPhone Duo, which comes up sideways). Set either way, since the simulator keeps whichever
        // way the last run left it.
        if ProcessInfo.processInfo.environment["PORTRAIT"] != nil {
            XCUIDevice.shared.orientation = .portrait
        } else if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30) || app.buttons["Home"].waitForExistence(timeout: 5))

        home()
        plan()
        transactions()
        entry()
        accounts()
        reports()
        settings()
    }

    /// The notice a new phone shows while its budget comes down from iCloud, which a test cannot
    /// stage for real.
    func testFirstDownloadNotice() {
        app = XCUIApplication()
        app.launchArguments += ["-skip-splash", "-reset-ui-state", "-no-cloud-sync", "-no-reminders", "-simulate-first-download"]
        app.launch()
        let notice = app.descendants(matching: .any).matching(identifier: "first-download-notice").firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 30), "the notice should say the budget is arriving")
        sleep(3)
        shot("02-first-download")
    }

    // MARK: - Tabs

    private func home() {
        tab("Home")
        shot("01-home")
    }

    private func plan() {
        tab("Plan")
        shot("10-plan")
        app.swipeUp()
        shot("11-plan-scrolled")
        app.swipeDown(); app.swipeDown()

        tap(app.buttons["month-name"])
        shot("12-month-picker")
        dismissSheet()

        let category = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "assigned")).firstMatch
        if tap(category) {
            shot("13-category-detail")
            app.swipeUp()
            shot("14-category-detail-scrolled")
            dismissSheet()
        }

        if tap(app.buttons["edit-plan"]) {
            _ = app.buttons["reorder-plan"].waitForExistence(timeout: 10)
            shot("15-edit-plan")
            let about = app.buttons["group-purpose"].firstMatch
            if tap(about) {
                _ = app.popovers.firstMatch.waitForExistence(timeout: 5)
                shot("16-group-purpose")
                app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            if tap(app.buttons["reorder-plan"]) {
                shot("17-reorder-plan")
                tap(app.buttons["reorder-plan"])
            }
            dismissSheet()
        }
    }

    private func transactions() {
        tab("Transactions")
        shot("20-transactions")

        if tap(app.buttons["scheduled-header"].firstMatch) {
            shot("21-transactions-scheduled-open")
            tap(app.buttons["scheduled-header"].firstMatch)
        }
        if tap(app.buttons["to-approve"].firstMatch) {
            shot("22-to-approve")
            back()
        }
        if tap(app.buttons["uncategorized"].firstMatch) {
            shot("23-uncategorized")
            back()
        }
        if tap(app.buttons["transaction-row"].firstMatch) {
            _ = app.buttons["Cancel"].waitForExistence(timeout: 5)
            shot("24-edit-transaction")
            app.swipeUp()
            shot("25-edit-transaction-scrolled")
            dismissSheet()
        }
    }

    /// A new entry: the keypad, the details beneath it, and each picker it opens.
    private func entry() {
        tab("Transactions")
        guard tap(app.buttons["add-transaction-floating"]) else { return }
        _ = app.buttons["keypad-done"].waitForExistence(timeout: 10)
        shot("30-new-transaction-keypad")
        tap(app.buttons["keypad-done"])
        shot("31-new-transaction")
        app.swipeUp()
        shot("32-new-transaction-details")
        app.swipeDown()

        if tap(app.buttons["account-picker"].firstMatch) {
            shot("33-account-picker")
            back()
        }
        if tap(app.buttons["category-picker"].firstMatch) {
            shot("34-category-picker")
            back()
        }
        if tap(app.buttons["currency-picker"].firstMatch) {
            shot("35-currency-picker")
            dismissSheet()
        }
        let transfer = app.switches["Transfer between accounts"]
        if transfer.waitForExistence(timeout: 3) {
            if transfer.value as? String != "1" { transfer.switches.firstMatch.tap() }
            if transfer.value as? String != "1" { transfer.tap() }
            shot("36-new-transfer")
        }
        dismissSheet()
        // Cancelling an entry with something in it may ask first.
        tap(app.buttons["Discard Changes"].firstMatch)
    }

    private func accounts() {
        tab("Accounts")
        shot("40-accounts")

        if tap(app.buttons["add-account"]) {
            shot("41-add-account")
            dismissSheet()
        }
        guard tap(app.buttons["account-row"].firstMatch) else { return }
        shot("42-register")
        if tap(app.buttons["reconcile"]) {
            shot("43-reconcile")
            dismissSheet()
        }
        if tap(app.buttons["account-settings"]) {
            shot("44-account-settings")
            back()
        }
        back()
    }

    private func reports() {
        tab("Reports")
        shot("50-reports")
        app.swipeUp()
        shot("51-reports-middle")
        app.swipeUp()
        shot("52-reports-lower")
    }

    /// Everything behind the gear on Home.
    private func settings() {
        tab("Home")
        guard tap(app.buttons["open-more"]) else { return }
        shot("60-more")
        app.swipeUp()
        shot("61-more-lower")
        app.swipeDown()

        for (label, name) in [
            ("Import from YNAB", "62-import"),
            ("Backups & Start Fresh", "63-backups"),
            ("Currency & FX", "64-fx"),
        ] {
            let link = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
            if tap(link) {
                shot(name)
                app.swipeUp()
                shot(name + "-lower")
                back()
            }
        }
        if tap(app.buttons["budget-check"]) {
            shot("65-budget-check")
            back()
        }
        app.swipeUp()
        if tap(app.buttons["reminder-settings"]) {
            shot("66-reminders")
            back()
        }
    }

    // MARK: - Moving about

    private func tab(_ name: String) {
        // On an iPad the tabs sit at the top, outside any tab bar.
        let inBar = app.tabBars.buttons[name]
        if inBar.exists { inBar.tap() } else { app.buttons[name].firstMatch.tap() }
        sleep(1)
    }

    @discardableResult
    private func tap(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 3), element.isHittable else { return false }
        element.tap()
        sleep(1)
        return true
    }

    private func back() {
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        sleep(1)
    }

    private func dismissSheet() {
        for label in ["Cancel", "Done"] {
            let button = app.navigationBars.buttons[label].firstMatch
            if button.exists && button.isHittable {
                button.tap()
                sleep(1)
                return
            }
        }
        app.swipeDown(velocity: .fast)
        sleep(1)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
