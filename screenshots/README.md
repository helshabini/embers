# Screenshots

Full-size iPhone screenshots (iPhone 18 Pro, 1206 × 2622) in light and dark, for the App Store
listing and the website. Compressed copies for the site are in `web/screenshots/`.

**They show a made-up budget, never a real one** — these are public. `web/tools/make-demo-budget.py`
writes it as a YNAB export, and `validate-import` should match it at 100% on all three figures:

```bash
python3 web/tools/make-demo-budget.py /tmp/demo.zip
C="$(xcrun simctl get_app_container booted com.helshabini.Embers data)/Library/Application Support"
cp "$C"/Embers-UITests.store* ~/embers-uitests-backup/       # the UI tests expect the real budget
rm "$C"/Embers-UITests.store*
cd Packages/EmbersCore && swift run seed-store /tmp/demo.zip "$C/Embers-UITests.store" && cd ../..
xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100
xcrun simctl ui booted appearance light    # then again with dark
xcodebuild test -project Embers.xcodeproj -scheme Embers \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:EmbersUITests/ScreenCatalogUITests/testCatalogueEveryScreen -resultBundlePath /tmp/shots.xcresult
xcrun xcresulttool export attachments --path /tmp/shots.xcresult --output-path /tmp/shots
```

Then restore the backed-up store. The files here are taken from the catalogue as: `home` 01-home,
`plan` 10-plan, `transactions` 20-transactions, `new-transaction` 30-new-transaction-keypad,
`accounts` 40-accounts, `reports` 50-reports, `net-worth` 51-reports-middle.

The demo budget's dates are fixed around 27 October 2026; move `TODAY` in the script to retake
them later, or the current month will be empty.
