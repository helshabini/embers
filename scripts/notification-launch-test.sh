#!/bin/zsh
# Runs NotificationLaunchUITests: a reminder tapped while Embers is closed must open it.
#
# The test runner cannot deliver a notification, so this sends one into the simulator every few
# seconds while the test runs; the test taps whichever arrives once the app has closed.
set -euo pipefail
cd "${0:A:h}/.."
device=${1:-iPhone 18 Pro}
payload=$(mktemp -t embers-push).apns
cat > "$payload" <<'JSON'
{"Simulator Target Bundle": "com.helshabini.Embers", "aps": {"alert": {"title": "Embers", "body": "Rent is due today"}, "category": "due"}, "kind": "due"}
JSON

# Passed into the runner as EMBERS_SENDS_NOTIFICATIONS; without it the test skips itself.
TEST_RUNNER_EMBERS_SENDS_NOTIFICATIONS=1 xcodebuild test -project Embers.xcodeproj -scheme Embers \
  -destination "platform=iOS Simulator,name=$device" \
  -only-testing:EmbersUITests/NotificationLaunchUITests "${@:2}" &
test=$!
sleep 60  # building and launching
while kill -0 $test 2>/dev/null; do
  xcrun simctl push "$device" com.helshabini.Embers "$payload" >/dev/null 2>&1 || true
  sleep 4
done
wait $test
