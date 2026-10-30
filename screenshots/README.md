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

## App Store sets

The listing wants iPhone 6.9″ (1320 × 2868, the iPhone 18 Pro Max), iPad 13″ (2064 × 2752, the iPad
Pro 13-inch) and Mac (2880 × 1800). They are not kept here; the last set was made on 31 Oct 2026.

- **iPhone and iPad:** the recipe above on each simulator, with `TEST_RUNNER_PORTRAIT=1` in front of
  `xcodebuild` for the iPad. Landscape screenshots come back on a portrait canvas, half black.
- **Mac:** seed the Mac app's `Embers-UITests.store` the same way (move the existing one aside
  first; seeding into it adds to it). Set the window and the look in the container's preferences,
  then run `MacScreenCatalogUITests/testAppStoreScreens` and put both back afterwards:
  ```bash
  P=~/Library/Containers/com.helshabini.Embers/Data/Library/Preferences/com.helshabini.Embers
  defaults write $P "NSWindow Frame main" "180 115 1440 900 0 0 1800 1130 "   # 2880 × 1800 at 2×
  defaults write $P appearance light                                         # then dark
  ```
  Not as a launch argument: under the test runner, `-appearance dark` leaves the app with no
  window. The window's rounded corners are transparent, which App Store Connect refuses, so
  flatten each image onto a solid background before uploading.
- **iPhone Duo** (optional until April 2027; it earns the "optimized for iPhone Duo" badge): the
  outer display is 1398 × 2034 and the inner 2853 × 2007, and the simulator needs the iOS 27.1
  runtime. It boots folded, and nothing on the command line unfolds it: do that by hand in Device
  Hub. Folded, the catalogue works as on any iPhone. Unfolded, XCTest's screenshots of the inner
  display come back black, so drive the app from a test that prints a marker on each screen and
  pauses, and take the picture from the host with `simctl io <device> screenshot
  --display=<inner display UUID>` (`simctl io <device> enumerate` lists them). Those keep the
  screen's rounded corners as transparency; flatten them.
- **A test run that seems to hang after its last test** is `xcodebuild` collecting diagnostics
  for up to ten minutes after a failure. Pass `-collect-test-diagnostics never`.
- **No window at all, from Xcode or a test?** Check that the iPhone app is not also installed on
  the Mac ("My Mac (Designed for iPad)" installs it under the same bundle ID). On 31 Oct 2026,
  unregistering it with `lsregister -u` brought the window back.
