#!/bin/bash
# Generates the Xcode project and runs the Mac app's tests, printing only the lines that
# matter. Run on the Mac, from anywhere:
#
#   TwoNoteMac/tools/test-mac.sh                                    unit tests
#   TwoNoteMac/tools/test-mac.sh -only-testing:TwoNoteMacUITests    the end-to-end run (see e2e-mac.sh)
#
# The app is signed (Apple Development, with the development provisioning profile that gives
# it the application identifier the data-protection Keychain needs; the tests use that
# Keychain), and signing only works in the desktop session, so when this runs over SSH it
# hands itself to tools/gui-job.sh and waits. The full log is .build/test.log.
cd "$(dirname "$0")/.." || exit 1
if [ -z "$TWONOTE_IN_GUI_JOB" ] && [ -n "$SSH_CONNECTION" ]; then
  # Default to the unit tests only.
  args=("$@")
  [ ${#args[@]} -eq 0 ] && args=(-only-testing:TwoNoteMacTests)
  exec env TWONOTE_JOB_WAIT="${TWONOTE_JOB_WAIT:-3600}" bash ../tools/gui-job.sh mactest \
    env TWONOTE_IN_GUI_JOB=1 TWONOTE_E2E_SERVER="${TWONOTE_E2E_SERVER:-}" TWONOTE_E2E_CONTROL="${TWONOTE_E2E_CONTROL:-}" \
    bash TwoNoteMac/tools/test-mac.sh "${args[@]}"
fi
[ $# -eq 0 ] && set -- -only-testing:TwoNoteMacTests
export PATH="/opt/homebrew/bin:$PATH"
mkdir -p .build
xcodegen > .build/xcodegen.log 2>&1 || { cat .build/xcodegen.log; exit 1; }

xcodebuild test -project TwoNoteMac.xcodeproj -scheme TwoNoteMac \
  -destination "platform=macOS,arch=arm64" -derivedDataPath .build/xcode \
  "$@" > .build/test.log 2>&1
status=$?
grep -E '^.{0,80} error:|^\*\* |^✘|^↳|Test run with|Executed [0-9]+ tests|^\[e2e\]|XCTAssert|Timed out|errSec|provisioning|Provisioning|requires a development team' .build/test.log | cut -c1-500
exit $status
