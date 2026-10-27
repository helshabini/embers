import XCTest

/// Walks every main screen in another language, saving a screenshot of each, and fails where a bar's
/// controls run into each other or off the screen.
///
/// iOS cannot say when a piece of text has been cut short — an accessibility label carries the full
/// text either way — so truncation is caught by looking: these screenshots are the review copy.
/// What can be measured is collision, which is how a too-long title or button fails in a bar.
///
/// Everything is found by identifier or position, never by its English label, since the labels are
/// what changes.
final class LocalizationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// The real translation, laid out right to left.
    func testTourInArabic() {
        tour(arguments: ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_EG"], prefix: "ar")
    }

    /// German runs longest of the languages shipped, so it is the real-world test of fitting.
    func testTourInGerman() {
        tour(arguments: ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"], prefix: "de")
    }

    /// No spaces between words, so lines break anywhere — and characters are wide.
    func testTourInJapanese() {
        tour(arguments: ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"], prefix: "ja")
    }

    /// Apple's pseudo-language: every localized string twice over. Long enough to show where a
    /// German or Russian translation would not fit, and any string still in plain English is one
    /// that was never localized.
    func testTourAtDoubleLength() {
        tour(
            arguments: ["-AppleLanguages", "(en)", "-NSDoubleLocalizedStrings", "YES"],
            prefix: "double"
        )
    }

    // MARK: - The walk

    private func tour(arguments: [String], prefix: String) {
        let app = XCUIApplication()
        app.launchArguments += ["-skip-splash", "-reset-ui-state", "-no-cloud-sync", "-no-reminders"] + arguments
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))

        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "\(prefix)-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            assertBarsFit(app, on: name)
        }

        let tabs = app.tabBars.firstMatch.buttons
        XCTAssertEqual(tabs.count, 5)

        // Home
        tabs.element(boundBy: 0).tap()
        shot("01-home")

        // Plan, and its editor with a group's description open
        tabs.element(boundBy: 1).tap()
        shot("02-plan")
        app.buttons["edit-plan"].tap()
        XCTAssertTrue(app.buttons["reorder-plan"].waitForExistence(timeout: 10))
        shot("03-edit-plan")
        let about = app.buttons["group-purpose"].firstMatch
        for _ in 0..<10 where !about.exists { app.swipeUp() }
        if about.exists {
            about.tap()
            _ = app.popovers.firstMatch.waitForExistence(timeout: 5)
            shot("04-group-purpose")
            app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        app.buttons["reorder-plan"].tap()
        shot("05-reorder")
        app.buttons["reorder-plan"].tap()
        // The confirmation button of the sheet's bar: the last one in it.
        app.navigationBars.firstMatch.buttons.allElementsBoundByIndex.last?.tap()

        // Transactions, and a new entry
        tabs.element(boundBy: 2).tap()
        shot("06-transactions")
        app.buttons["add-transaction-floating"].tap()
        XCTAssertTrue(app.buttons["keypad-done"].waitForExistence(timeout: 10))
        shot("07-new-transaction")
        app.buttons["keypad-done"].tap()
        app.swipeUp()
        shot("08-new-transaction-details")
        app.navigationBars.firstMatch.buttons.firstMatch.tap()

        // Accounts, and one register
        tabs.element(boundBy: 3).tap()
        shot("09-accounts")
        let account = app.buttons["account-row"].firstMatch
        if account.waitForExistence(timeout: 5) {
            account.tap()
            shot("10-register")
            app.navigationBars.firstMatch.buttons.firstMatch.tap()
        }

        // Reports
        tabs.element(boundBy: 4).tap()
        shot("11-reports")
        app.swipeUp()
        shot("12-reports-lower")

        // More, from Home
        tabs.element(boundBy: 0).tap()
        app.buttons["open-more"].tap()
        XCTAssertTrue(app.buttons["language-settings"].waitForExistence(timeout: 10))
        shot("13-more")
        app.swipeUp()
        shot("14-more-lower")
        app.swipeDown()
        app.buttons["budget-check"].tap()
        shot("15-budget-check")
    }

    // MARK: - Fitting

    /// No two controls in a bar overlap, and none runs past the screen's edges.
    private func assertBarsFit(_ app: XCUIApplication, on screen: String) {
        let width = app.windows.firstMatch.frame.width
        for bar in app.navigationBars.allElementsBoundByIndex + app.tabBars.allElementsBoundByIndex {
            let items = (bar.buttons.allElementsBoundByIndex + bar.staticTexts.allElementsBoundByIndex)
                .filter { $0.exists && $0.isHittable && !$0.frame.isEmpty }
            for item in items {
                XCTAssertTrue(
                    item.frame.minX >= -1 && item.frame.maxX <= width + 1,
                    "\(screen): “\(item.label)” runs off the screen"
                )
            }
            // A tab bar's buttons overlap by design — each reaches into its neighbour's padding —
            // so only the navigation bars are checked for collisions. A tab title too long for its
            // slot is cut short instead, which the screenshots show.
            guard bar.elementType == .navigationBar else { continue }
            for (index, one) in items.enumerated() {
                for other in items.dropFirst(index + 1) {
                    // A label inside its own button shares its frame; that is not a collision.
                    guard !one.frame.contains(other.frame), !other.frame.contains(one.frame) else {
                        continue
                    }
                    let overlap = one.frame.intersection(other.frame)
                    XCTAssertTrue(
                        overlap.isNull || overlap.width < 2,
                        "\(screen): “\(one.label)” and “\(other.label)” overlap in the bar"
                    )
                }
            }
        }
    }
}
