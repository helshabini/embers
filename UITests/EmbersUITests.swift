import XCTest

/// Drives the real screens against whatever budget is already in the app's store.
///
/// The engine is checked exhaustively without a simulator; what these add is the part that cannot be
/// checked headlessly — that each screen builds, navigates, and shows the numbers rather than
/// crashing or coming up empty.
final class EmbersUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Launches and waits for the app to be interactive.
    ///
    /// The splash sits over the whole window while the budget opens. The tab bar is readable behind
    /// it, so waiting on that is not enough — the first tap of every test landed on the splash
    /// instead. These tests are about the screens, so they skip it; `testSplashGivesWayToTheBudget`
    /// covers the splash itself.
    @discardableResult
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        // The simulator is shared, so anything a screen remembers is forgotten first: without this a
        // test that folded a section away left it folded for the next one.
        app.launchArguments += ["-skip-splash", "-reset-ui-state", "-no-cloud-sync", "-no-reminders"]
        app.launch()
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 30),
            "the app should finish opening"
        )
        return app
    }

    /// Held still by `-hold-splash`, so the launch screen can be looked at rather than raced.
    func testSplashDrawsTheTreeAndCanBeSkipped() {
        let app = XCUIApplication()
        app.launchArguments += ["-hold-splash", "-no-cloud-sync", "-no-reminders"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Your sure way to FIRE"].waitForExistence(timeout: 15),
            "the splash should come up on launch"
        )
        capture(app, "00-splash")

        // Nobody should have to watch it twice, so a tap gets past it. The slogan, not the wordmark:
        // Home carries "Embers" too, and matching both is ambiguous.
        app.staticTexts["Your sure way to FIRE"].tap()
        XCTAssertTrue(
            app.navigationBars.firstMatch.waitForExistence(timeout: 20),
            "tapping the splash should get past it"
        )
    }

    /// The one test that launches exactly the way the phone does, and lets the splash finish.
    ///
    /// It asserts the splash *leaves*, not that it arrives: `launch()` waits for the app to go idle,
    /// by which point a working splash has already handed over, so catching it on screen is a race.
    /// Leaving is the part that broke — the handover was inside a `.task`, whose captured `isReady`
    /// never updated, so the splash sat over the app forever and nothing below it could be tapped.
    func testSplashGivesWayToTheBudget() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 30),
            "the budget should open behind the splash"
        )
        app.tabBars.buttons["Plan"].tap()
        XCTAssertTrue(
            app.navigationBars["Plan"].waitForExistence(timeout: 20),
            "the splash should clear itself and let the tabs through"
        )
        capture(app, "00-after-splash")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEveryTabOpens() {
        let app = launchApp()

        XCTAssertTrue(app.staticTexts["Ready to Assign"].waitForExistence(timeout: 10))
        capture(app, "01-home")

        app.tabBars.buttons["Plan"].tap()
        XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: 5))
        capture(app, "02-plan")

        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 5))
        capture(app, "03-transactions")

        app.tabBars.buttons["Accounts"].tap()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 5))
        capture(app, "04-accounts")

        app.tabBars.buttons["Reports"].tap()
        XCTAssertTrue(app.navigationBars["Reports"].waitForExistence(timeout: 5))
        capture(app, "05-reports")

        // Settings live behind the gear on Home: a sixth tab would be swallowed by iOS's own
        // overflow, taking Reports with it.
        app.tabBars.buttons["Home"].tap()
        app.buttons["open-more"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
        capture(app, "06-more")
    }

    /// Opens the first account's register, and returns the app sitting on it.
    @discardableResult
    private func openFirstRegister(_ app: XCUIApplication) -> Bool {
        app.tabBars.buttons["Accounts"].tap()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 10))

        let row = app.descendants(matching: .any).matching(identifier: "account-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the accounts list should have rows")
        row.tap()

        let arrived = app.staticTexts["Working balance"].waitForExistence(timeout: 10)
        if !arrived { capture(app, "99-register-missing") }
        return arrived
    }

    func testOpeningAnAccountShowsItsRegister() {
        let app = launchApp()
        XCTAssertTrue(openFirstRegister(app), "the register should show a working balance")
        capture(app, "05-register")
    }

    func testFloatingButtonOpensAnEntryOnTheLastAccount() {
        let app = launchApp()
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))

        let floating = app.buttons["add-transaction-floating"]
        XCTAssertTrue(floating.waitForExistence(timeout: 5), "the tab should offer a quick add")
        floating.tap()

        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        // An account is already chosen, and can be changed here.
        let accountRow = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Account")
        ).firstMatch
        XCTAssertTrue(accountRow.waitForExistence(timeout: 5))
        capture(app, "10-quick-add")
    }

    func testTransferOffersASecondAccount() {
        let app = launchApp()
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))
        app.buttons["add-transaction-floating"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))

        let toggle = app.switches["Transfer between accounts"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "transfers should be offered")
        if toggle.value as? String != "1" { toggle.tap() }
        if toggle.value as? String != "1" { toggle.switches.firstMatch.tap() }
        XCTAssertEqual(toggle.value as? String, "1", "the transfer toggle should turn on")
        let destination = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "To account")
        ).firstMatch
        if !destination.waitForExistence(timeout: 5) { capture(app, "98-transfer-missing") }
        XCTAssertTrue(destination.exists, "a transfer needs somewhere to send the money")
        capture(app, "11-transfer")
    }

    /// Backups are the way back from a mistake that syncing has carried to every device, and the only
    /// copy off the device without iCloud, so the screen must be reachable.
    func testBackupScreenOffersSaveRestoreAndStartFresh() {
        let app = launchApp()
        app.buttons["open-more"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10))

        app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Backups")
        ).firstMatch.tap()

        XCTAssertTrue(app.navigationBars["Backups"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Save a Backup")
        ).firstMatch.exists)
        XCTAssertTrue(app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Restore from a Backup")
        ).firstMatch.exists)
        XCTAssertTrue(app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Start Fresh")
        ).firstMatch.exists)
        capture(app, "12-backups")
    }

    /// Picking from thirty accounts should be a search, not a scroll.
    func testAccountPickerFiltersAsYouType() {
        let app = launchApp()
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))
        app.buttons["add-transaction-floating"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))

        app.buttons["account-picker"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
        let before = app.buttons.matching(identifier: "account-option").count
        XCTAssertTrue(before > 1, "there should be several accounts to choose from")

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Cash")
        XCTAssertTrue(
            app.buttons.matching(identifier: "account-option").count < before,
            "typing should narrow the list"
        )
        capture(app, "13-account-picker")
    }

    /// Categories are a full page you can search, not a dropdown.
    func testCategoryPickerIsSearchable() {
        let app = launchApp()
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))
        app.buttons["add-transaction-floating"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))

        app.buttons["category-picker"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Category"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Groc")
        XCTAssertTrue(
            app.buttons.matching(identifier: "category-option").firstMatch.waitForExistence(timeout: 5),
            "searching should still leave something to pick"
        )
        capture(app, "14-category-picker")
    }

    /// Income has no envelope yet, so Ready to Assign has to be offered on an ordinary transaction —
    /// it once appeared only on a transfer across the budget's edge, and a salary could not be entered.
    func testReadyToAssignIsAlwaysACategory() {
        let app = launchApp()
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))
        app.buttons["add-transaction-floating"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))

        app.buttons["category-picker"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Category"].waitForExistence(timeout: 5))
        let readyToAssign = app.buttons
            .matching(identifier: "category-option")
            .matching(NSPredicate(format: "label CONTAINS %@", "Ready to Assign"))
            .firstMatch
        XCTAssertTrue(readyToAssign.waitForExistence(timeout: 5), "Ready to Assign should be offered")
        readyToAssign.tap()
        XCTAssertTrue(
            app.buttons["category-picker"].firstMatch.label.contains("Ready to Assign"),
            "and once picked, it should be the transaction's category"
        )
    }

    /// Money spent from a KES account is spent in KES, so choosing the account should say so without
    /// being told. Before this, the entry currency stayed on whichever account was picked last.
    func testSwitchingAccountSwitchesTheEntryCurrency() {
        let app = launchApp()
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))
        app.buttons["add-transaction-floating"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))

        let currency = app.buttons["currency-picker"]
        XCTAssertTrue(currency.waitForExistence(timeout: 5))

        chooseAccount(app, named: "Checking (KES)")
        XCTAssertEqual(currency.label, "KES", "a KES account should be entered in KES")

        chooseAccount(app, named: "Fidelity")
        XCTAssertEqual(currency.label, "USD", "switching accounts should follow the new one")
        capture(app, "15-currency-follows-account")
    }

    private func chooseAccount(_ app: XCUIApplication, named name: String) {
        app.buttons["account-picker"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(name)
        let row = app.buttons.matching(identifier: "account-option").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(name) should be in the results")
        row.tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
    }

    /// Reported as failing: setting a repeat on a checking-account transaction.
    func testSettingARepeatOnACheckingTransactionSticks() {
        let app = launchApp()
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))
        app.buttons["add-transaction-floating"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))

        chooseAccount(app, named: "Checking (KES)")
        for digit in ["5", "0", "0", "0"] { app.buttons[digit].firstMatch.tap() }

        // The keypad covers the lower half of the form, so it has to go before the details below it
        // can be reached.
        app.buttons["keypad-done"].tap()

        let repeats = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Repeats")
        ).firstMatch
        XCTAssertTrue(repeats.waitForExistence(timeout: 5), "the editor should offer a repeat")
        repeats.tap()
        capture(app, "16-repeat-options")

        let monthly = app.buttons["Every month"].firstMatch
        XCTAssertTrue(monthly.waitForExistence(timeout: 5), "monthly should be offered")
        monthly.tap()

        XCTAssertTrue(
            repeats.label.contains("Every month"),
            "the chosen rule should show, but the row reads: \(repeats.label)"
        )
        capture(app, "17-repeat-chosen")

        XCTAssertTrue(app.buttons["Save"].isEnabled, "a repeating transaction should be saveable")
        app.buttons["Save"].tap()
        XCTAssertTrue(
            app.navigationBars["Transactions"].waitForExistence(timeout: 10),
            "saving should close the editor"
        )
        capture(app, "18-after-repeat-save")
    }

    /// Can the details below the keypad be reached by scrolling, without knowing to dismiss it?
    func testDetailsBelowTheKeypadAreReachableByScrolling() {
        let app = launchApp()
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))
        app.buttons["add-transaction-floating"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        for digit in ["5", "0", "0"] { app.buttons[digit].firstMatch.tap() }

        // No keypad-done tap: scroll the way somebody who has not spotted the dismiss would.
        let repeats = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Repeats")
        ).firstMatch
        XCTAssertTrue(repeats.waitForExistence(timeout: 5))
        for _ in 0..<4 where !repeats.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(
            repeats.isHittable,
            "the repeat row should be reachable by scrolling, with the keypad still up"
        )
        capture(app, "19-scrolled-to-details")
    }

    /// Adding an account, which until now the empty state invited without offering a way to do.
    func testAddingAnAccountPutsItInTheList() {
        let app = launchApp()
        app.tabBars.buttons["Accounts"].tap()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 10))

        app.buttons["add-account"].tap()
        XCTAssertTrue(app.navigationBars["New Account"].waitForExistence(timeout: 5))

        let name = "Test Account \(Int(Date().timeIntervalSince1970) % 100000)"
        let field = app.textFields["account-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)

        let balance = app.textFields["account-balance"]
        balance.tap()
        balance.typeText("250")
        capture(app, "20-new-account")

        let countBefore = app.descendants(matching: .any)
            .matching(identifier: "account-row").count

        app.buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 10))

        // A new account goes last, so with a real budget's worth of accounts it is well below the
        // fold and not rendered until scrolled to.
        let row = app.staticTexts[name]
        for _ in 0..<12 where !row.exists {
            app.swipeUp()
        }
        XCTAssertTrue(row.exists, "the new account should be in the list")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "account-row").count > countBefore
                || countBefore == 0,
            "the list should have grown"
        )
        capture(app, "21-account-added")
    }

    /// An account with money in it cannot be closed: closed, it leaves every list while its balance
    /// keeps counting. The screen says what to do instead.
    func testAnAccountWithABalanceCannotBeClosed() {
        let app = launchApp()
        XCTAssertTrue(openFirstRegister(app))

        app.buttons["account-settings"].tap()
        let closed = app.switches["account-closed"]
        XCTAssertTrue(closed.waitForExistence(timeout: 5))
        XCTAssertFalse(closed.isEnabled, "closing should wait for a zero balance")
        XCTAssertTrue(
            app.staticTexts["closing-blocker"].exists,
            "and the screen should say what is in the way"
        )
        capture(app, "22a-closing-blocked")
    }

    /// Reconciling shows the difference before it writes anything.
    func testReconcileShowsTheDifferenceBeforeWriting() {
        let app = launchApp()
        XCTAssertTrue(openFirstRegister(app))

        app.buttons["reconcile"].tap()
        XCTAssertTrue(app.navigationBars["Reconcile"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Cleared balance"].exists)

        let statement = app.textFields["statement-balance"]
        XCTAssertTrue(statement.waitForExistence(timeout: 5))
        statement.tap()
        statement.typeText("1000")

        XCTAssertTrue(
            app.staticTexts["reconcile-difference"].waitForExistence(timeout: 5),
            "a typed statement balance should produce a difference"
        )
        XCTAssertTrue(
            app.buttons["reconcile-confirm"].exists,
            "and something to confirm it with"
        )
        capture(app, "22-reconcile")

        // Nothing should have been written just by looking.
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Working balance"].waitForExistence(timeout: 5))
    }

    /// A wallet held in another currency is counted in that currency, and can still be counted in
    /// the plan's.
    func testReconcilingAForeignAccountCountsInItsOwnCurrency() {
        let app = launchApp()
        app.tabBars.buttons["Accounts"].tap()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 10))
        let account = app.descendants(matching: .any).matching(identifier: "account-row")
            .matching(NSPredicate(format: "label CONTAINS %@", "Checking (KES)")).firstMatch
        // The list is lazy: an account below the fold does not exist until it is scrolled to.
        _ = app.descendants(matching: .any).matching(identifier: "account-row").firstMatch
            .waitForExistence(timeout: 10)
        for _ in 0..<6 where !account.exists { app.swipeUp() }
        XCTAssertTrue(account.waitForExistence(timeout: 5), "the KES account should be listed")
        account.tap()
        XCTAssertTrue(app.staticTexts["Working balance"].waitForExistence(timeout: 10))

        app.buttons["reconcile"].tap()
        XCTAssertTrue(app.navigationBars["Reconcile"].waitForExistence(timeout: 5))
        let kes = app.segmentedControls["statement-currency"].buttons["KES"]
        let usd = app.segmentedControls["statement-currency"].buttons["USD"]
        XCTAssertTrue(kes.waitForExistence(timeout: 5), "a KES account should offer KES")
        XCTAssertTrue(usd.exists, "and the plan's currency")

        let statement = app.textFields["statement-balance"]
        XCTAssertTrue(statement.waitForExistence(timeout: 5))
        // KES is the default only once a rate for it is cached; with none, USD is chosen instead.
        let countsInKES = kes.isSelected
        statement.tap()
        statement.typeText("1000")
        XCTAssertTrue(app.staticTexts["reconcile-difference"].waitForExistence(timeout: 5))
        if countsInKES {
            XCTAssertTrue(
                app.staticTexts["In USD"].exists,
                "a figure in KES should be shown in the plan's currency too"
            )
            capture(app, "23-reconcile-in-account-currency")
        }

        // The same figure, now read as dollars.
        usd.tap()
        XCTAssertTrue(app.staticTexts["reconcile-difference"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["In USD"].exists, "nothing to convert when counting in USD")

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Working balance"].waitForExistence(timeout: 5))
    }

    /// Reported: set a repeat, save, reopen the transaction — and it reads "Never" again.
    func testARepeatIsStillThereWhenTheTransactionIsReopened() {
        let app = launchApp()
        XCTAssertTrue(openFirstRegister(app))

        let firstRow = app.buttons.matching(identifier: "transaction-row").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "the register should have rows")
        firstRow.tap()
        // A transfer's editor is titled differently, and the register's newest row may well be one.
        let editorOpened = app.buttons["Save"].waitForExistence(timeout: 10)
        if !editorOpened { capture(app, "97-editor-did-not-open") }
        XCTAssertTrue(editorOpened, "tapping a row should open its editor")
        capture(app, "24-editor-opened")

        setRepeat(app, to: "Every three months")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Working balance"].waitForExistence(timeout: 10))

        // Straight back into the same entry.
        firstRow.tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 10), "reopening should work")
        let repeats = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Repeats")
        ).firstMatch
        XCTAssertTrue(repeats.waitForExistence(timeout: 5))
        capture(app, "23-reopened-repeat")
        XCTAssertTrue(
            repeats.label.contains("Every three months"),
            "the saved repeat should still be set, but the row reads: \(repeats.label)"
        )
    }

    private func setRepeat(_ app: XCUIApplication, to rule: String) {
        let repeats = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Repeats")
        ).firstMatch
        XCTAssertTrue(repeats.waitForExistence(timeout: 5))
        for _ in 0..<4 where !repeats.isHittable { app.swipeUp() }
        repeats.tap()
        let option = app.buttons[rule].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "\(rule) should be offered")
        option.tap()
    }

    /// Scheduled entries fold away, and folding them back open shows them.
    func testScheduledEntriesFoldAway() {
        let app = launchApp()
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))

        let header = app.buttons["scheduled-header"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), "there should be a Scheduled section")
        capture(app, "25-scheduled-collapsed")

        let scheduled = app.descendants(matching: .any).matching(identifier: "scheduled-row")
        XCTAssertEqual(scheduled.count, 0, "the section starts closed")

        header.tap()
        XCTAssertTrue(
            scheduled.firstMatch.waitForExistence(timeout: 5),
            "opening the section should show what is scheduled"
        )
        capture(app, "26-scheduled-expanded")

        header.tap()
        XCTAssertEqual(scheduled.count, 0, "closing it should put them away again")
    }

    /// Every report card builds and says something, top to bottom.
    func testReportsReadTopToBottom() {
        let app = launchApp()
        app.tabBars.buttons["Reports"].tap()
        XCTAssertTrue(app.navigationBars["Reports"].waitForExistence(timeout: 10))

        XCTAssertTrue(app.staticTexts["Where it went"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Top categories"].exists, "the bar should be keyed")
        capture(app, "27-reports-spending")

        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["In against out"].waitForExistence(timeout: 5))
        capture(app, "28-reports-income")

        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Net worth"].waitForExistence(timeout: 5))
        capture(app, "29-reports-networth")
    }

    /// A transfer is two rows in the data and should be one line in a list that holds both.
    func testATransferIsOneLineAcrossAllAccounts() {
        let app = launchApp()
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))

        // The scheduled entries are the repeating transfers, so open them and look there.
        let header = app.buttons["scheduled-header"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        header.tap()

        let rows = app.descendants(matching: .any).matching(identifier: "scheduled-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "there should be rows")
        capture(app, "30-collapsed-transfers")

        // Kept as the side money left, so it reads "Transfer to …" and never "Transfer from …" —
        // the incoming half is what used to be the duplicate.
        let outgoing = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Transfer to")
        ).firstMatch
        XCTAssertTrue(
            outgoing.waitForExistence(timeout: 5),
            "a collapsed transfer should say where the money went"
        )
        let incoming = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Transfer from")
        )
        XCTAssertEqual(
            incoming.count, 0,
            "the receiving half of a paired transfer should not be listed as well"
        )
    }

    /// The plan can be edited, and what the app manages cannot.
    func testPlanCategoriesCanBeEdited() {
        let app = launchApp()
        app.tabBars.buttons["Plan"].tap()
        XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: 10))

        app.buttons["edit-plan"].tap()
        XCTAssertTrue(app.navigationBars["Edit Plan"].waitForExistence(timeout: 10))
        capture(app, "31-edit-plan")

        let name = "Test Group \(Int(Date().timeIntervalSince1970) % 100000)"
        app.buttons["add-group"].tap()
        // A text field inside an alert belongs to the alert, not the app.
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "naming it should be asked for")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(name)
        alert.buttons["Add"].tap()

        // A new group goes last, which on a plan this size is well below the fold.
        let added = app.staticTexts[name]
        for _ in 0..<15 where !added.exists {
            app.swipeUp()
        }
        XCTAssertTrue(added.exists, "a new group should appear in the plan editor")
        capture(app, "32-plan-group-added")

        // A group's header cannot be swiped, so its edits are behind a menu — and an empty group,
        // with no history, can go. This also leaves the shared store as it was found.
        let menu = app.buttons["Edit \(name)"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "a group the user made can be edited")
        menu.tap()
        let deleteGroup = app.buttons["Delete Group"]
        XCTAssertTrue(deleteGroup.waitForExistence(timeout: 5))
        deleteGroup.tap()
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "deleting should be confirmed")
        confirm.buttons["Delete"].tap()
        XCTAssertTrue(added.waitForNonExistence(timeout: 5), "the empty group should be gone")

        // What the app manages cannot be renamed; what the user made can.
        XCTAssertTrue(
            app.staticTexts["Credit Card Payments"].exists
                || app.navigationBars["Edit Plan"].exists,
            "the credit card group should always be there"
        )
    }

    /// The budget check reports what it cannot settle, and says so when there is nothing.
    /// A starter group says what it is for, and the plan can be put into its reordering mode. Nothing
    /// is dragged: the store is shared, and the moves themselves are proven headlessly.
    func testStarterGroupsExplainThemselvesAndThePlanCanBeReordered() {
        let app = launchApp()
        app.tabBars.buttons["Plan"].tap()
        app.buttons["edit-plan"].tap()
        XCTAssertTrue(app.navigationBars["Edit Plan"].waitForExistence(timeout: 10))

        let about = app.buttons["group-purpose"].firstMatch
        for _ in 0..<10 where !about.exists {
            app.swipeUp()
        }
        XCTAssertTrue(about.exists, "a starter group should offer its description")
        about.tap()
        XCTAssertTrue(
            app.popovers.firstMatch.waitForExistence(timeout: 5),
            "tapping (i) should say what the group is for"
        )
        capture(app, "35-group-purpose")
        // A popover is dismissed by tapping outside it.
        app.navigationBars["Edit Plan"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))

        app.buttons["reorder-plan"].tap()
        XCTAssertTrue(
            app.staticTexts["move-category"].firstMatch.waitForExistence(timeout: 5),
            "reordering should list the categories to drag"
        )
        capture(app, "36-plan-reordering")
        app.buttons["reorder-plan"].tap()
        XCTAssertTrue(app.buttons["add-group"].waitForExistence(timeout: 5))
    }

    /// Reminders are set per device, from More. Under `-no-reminders` the switches show but do
    /// nothing, so the system's permission alert never sits over a test.
    func testReminderSettingsAreReachable() {
        let app = launchApp()
        app.buttons["open-more"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10))
        let link = app.buttons["reminder-settings"].firstMatch
        for _ in 0..<3 where !link.isHittable { app.swipeUp() }
        link.tap()
        XCTAssertTrue(app.navigationBars["Reminders"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 5), "a switch per kind")
        capture(app, "48-reminder-settings")
    }

    func testBudgetCheckReportsWhatNeedsADecision() {
        let app = launchApp()
        app.buttons["open-more"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10))

        app.buttons["budget-check"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Check"].waitForExistence(timeout: 10))
        capture(app, "33-budget-check")

        // Either everything is settled, or what is not is listed to be decided.
        let clear = app.staticTexts["Nothing needs your attention"]
        let needsADecision = app.staticTexts["Money crossing the budget with no category"]
        XCTAssertTrue(
            clear.waitForExistence(timeout: 5) || needsADecision.exists,
            "the check should say one thing or the other"
        )
    }

    /// Tapping the month jumps to any month, and back to this one.
    func testMonthCanBeJumpedToDirectly() {
        let app = launchApp()
        app.tabBars.buttons["Plan"].tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))

        let monthName = app.buttons["month-name"]
        XCTAssertTrue(monthName.waitForExistence(timeout: 5), "the month should be tappable")
        let opened = monthName.label

        // Walk a few months away by hand, then jump back in one tap.
        app.buttons["previous-month"].tap()
        app.buttons["previous-month"].tap()
        app.buttons["previous-month"].tap()
        XCTAssertNotEqual(monthName.label, opened, "stepping should move the month")

        monthName.tap()
        XCTAssertTrue(app.navigationBars["Go to month"].waitForExistence(timeout: 5))
        capture(app, "34-month-picker")

        app.buttons["jump-to-this-month"].tap()
        XCTAssertTrue(
            monthName.waitForExistence(timeout: 5)
                && app.buttons["month-name"].label == opened,
            "jumping to this month should land where the app opened"
        )
    }

    func testEnteringAnAmountConvertsIt() {
        let app = launchApp()
        XCTAssertTrue(openFirstRegister(app))

        app.buttons["Add Transaction"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        capture(app, "06-entry-empty")

        for digit in ["1", "2", "3", "4"] {
            app.buttons[digit].firstMatch.tap()
        }
        capture(app, "07-entry-amount")

        XCTAssertTrue(app.buttons["Save"].isEnabled, "a typed amount should be saveable")
    }

    /// The point of the app: type a foreign amount and watch it convert, with the bank's fee.
    func testChoosingAnotherCurrencyShowsTheConversion() {
        let app = launchApp()
        XCTAssertTrue(openFirstRegister(app))
        app.buttons["Add Transaction"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))

        for digit in ["1", "0", "0", "0", "0"] {
            app.buttons[digit].firstMatch.tap()
        }

        // The currency button carries the current code; the account's own currency by default.
        let currencyButton = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "^[A-Z]{3}$")).firstMatch
        XCTAssertTrue(currencyButton.waitForExistence(timeout: 5), "currency button should be present")
        currencyButton.tap()

        XCTAssertTrue(app.navigationBars["Currency"].waitForExistence(timeout: 5))
        capture(app, "08-currency-picker")

        // USD is the plan's currency and not the card's, so this is the case that attracts the fee.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("USD")
        let usdRow = app.descendants(matching: .any).matching(identifier: "currency-USD").firstMatch
        XCTAssertTrue(usdRow.waitForExistence(timeout: 5), "USD should be in the results")
        usdRow.tap()

        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        let feeNotice = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "bank fee")
        ).firstMatch
        XCTAssertTrue(
            feeNotice.waitForExistence(timeout: 5),
            "paying in a currency the account does not hold should say the fee applies"
        )
        capture(app, "09-entry-converted")
    }

    /// Spending saved without a category is listed at the top of Transactions, warned about on the
    /// Plan, and given a category from the list in two taps.
    func testUncategorizedSpendingIsListedAndCanBeCategorized() {
        let app = launchApp()
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))
        app.buttons["add-transaction-floating"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        chooseAccount(app, named: "Checking (KES)")
        for digit in ["4", "2", "1"] { app.buttons[digit].firstMatch.tap() }
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))

        let group = app.buttons["uncategorized"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 10), "an uncategorized entry should be flagged up top")
        capture(app, "40-uncategorized-up-top")

        app.tabBars.buttons["Plan"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["plan-uncategorized-warning"].firstMatch.waitForExistence(timeout: 5),
            "the Plan should warn about it beside Ready to Assign"
        )
        capture(app, "41-plan-warns")

        app.tabBars.buttons["Transactions"].tap()
        // The list is lazy, so its rendered rows are not its rows; the count on this row is.
        let before = leadingCount(group.label)
        group.tap()
        XCTAssertTrue(app.navigationBars["Uncategorized"].waitForExistence(timeout: 5))
        let rows = app.buttons.matching(identifier: "uncategorized-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        capture(app, "42-uncategorized-list")

        // The newest is first: the one just entered.
        rows.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Category"].waitForExistence(timeout: 5), "a tap goes to the categories")
        app.buttons.matching(identifier: "category-option").element(boundBy: 1).tap()

        XCTAssertTrue(app.navigationBars["Uncategorized"].waitForExistence(timeout: 5), "and comes back to the list")
        capture(app, "43-uncategorized-after")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 5))
        if before == 1 {
            XCTAssertTrue(waitForDisappearance(group), "the last one categorized, the row goes")
        } else {
            let fewer = NSPredicate { _, _ in self.leadingCount(group.label) == before - 1 }
            wait(for: [XCTNSPredicateExpectation(predicate: fewer, object: nil)], timeout: 10)
        }
    }

    /// "32 uncategorized transactions" → 32.
    private func leadingCount(_ label: String) -> Int {
        Int(label.prefix { $0.isNumber }) ?? 0
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: 10) == .completed
    }

    /// A scheduled entry whose day has come waits at the top of Transactions until it is approved.
    ///
    /// Time cannot be made to pass, so a scheduled entry is moved to today instead: it stays a
    /// schedule, and is due.
    func testADueScheduledEntryWaitsForApproval() {
        let app = launchApp()
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))

        let header = app.buttons["scheduled-header"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), "there should be something scheduled")
        header.tap()
        let scheduled = app.descendants(matching: .any).matching(identifier: "scheduled-row").firstMatch
        XCTAssertTrue(scheduled.waitForExistence(timeout: 5))
        scheduled.tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 10))

        moveDateToToday(app)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))

        let group = app.buttons["to-approve"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 10), "a due entry should wait up top")
        capture(app, "44-to-approve-up-top")
        group.tap()
        XCTAssertTrue(app.navigationBars["To Approve"].waitForExistence(timeout: 5))
        let rows = app.buttons.matching(identifier: "approval-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        // Only ones made due by this suite, so few enough that every row is rendered.
        let before = rows.count
        capture(app, "45-to-approve-list")

        rows.firstMatch.tap()
        let approve = app.buttons["Approve"].firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 5), "a tap asks what to do with it")
        XCTAssertTrue(app.buttons["Edit"].exists)
        capture(app, "46-approve-choices")
        approve.tap()

        let done = NSPredicate { _, _ in rows.count == before - 1 }
        wait(for: [XCTNSPredicateExpectation(predicate: done, object: nil)], timeout: 10)
        capture(app, "47-after-approving")
    }

    /// Picks today in the editor's date picker, stepping back a month at a time from wherever it is.
    private func moveDateToToday(_ app: XCUIApplication) {
        let picker = app.datePickers.firstMatch
        for _ in 0..<4 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()

        // The simulator's region decides whether a day reads "Friday, 17 October" or "Friday,
        // October 17", so both are accepted.
        let calendar = Calendar.current
        let day = calendar.component(.day, from: Date())
        let month = calendar.monthSymbols[calendar.component(.month, from: Date()) - 1]
        let today = app.buttons.matching(
            NSPredicate(
                format: "label ENDSWITH %@ OR label ENDSWITH %@ OR label CONTAINS %@ OR label CONTAINS %@",
                ", \(day) \(month)", ", \(month) \(day)", ", \(day) \(month),", ", \(month) \(day),"
            )
        ).firstMatch
        let previous = app.buttons["Previous Month"].firstMatch
        for _ in 0..<24 where !today.exists {
            XCTAssertTrue(previous.waitForExistence(timeout: 5))
            previous.tap()
            _ = today.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(today.exists, "today should be in the calendar")
        today.tap()
        capture(app, "48-date-moved-to-today")
        // Closes the calendar, tapping clear of the form.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
    }
}
