#!/bin/bash
# Generates the Xcode project and runs the app's tests in the simulator, printing only the
# lines that matter. Run on the Mac, from anywhere:
#
#   tools/test.sh -only-testing:TwoNoteTests              unit tests (in-memory server)
#   tools/test.sh -only-testing:TwoNoteUITests            the end-to-end run (see tools/e2e.sh)
#
# TWONOTE_SIM picks the simulator (default "iPhone Duo"). The full log is .build/test.log.
# TWONOTE_IOS lowers the deployment target of this run's generated project (not project.yml),
# for simulators on an older system: the iPad simulators on this Mac are iOS 27.0, e.g.
#
#   TWONOTE_SIM="iPad (A16)" TWONOTE_IOS=27.0 tools/test.sh -only-testing:TwoNoteTests
cd "$(dirname "$0")/.." || exit 1
mkdir -p .build
xcodegen > .build/xcodegen.log 2>&1 || { cat .build/xcodegen.log; exit 1; }
if [ -n "$TWONOTE_IOS" ]; then
  sed -i '' "s/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]*;/IPHONEOS_DEPLOYMENT_TARGET = $TWONOTE_IOS;/" TwoNote.xcodeproj/project.pbxproj
fi

xcodebuild test -project TwoNote.xcodeproj -scheme TwoNote \
  -destination "platform=iOS Simulator,name=${TWONOTE_SIM:-iPhone Duo}" \
  -derivedDataPath .build/xcode "$@" > .build/test.log 2>&1 &
build=$!
while kill -0 "$build" 2>/dev/null; do
  # After a failing run this Xcode spends up to ten minutes in `simctl diagnose`; the tests
  # are over by then, so cut it short.
  pkill -f "simctl diagnose" 2>/dev/null
  sleep 2
done
wait "$build"
status=$?
grep -E '^.{0,80} error:|^\*\* |^✘|^↳|Test run with|Executed [0-9]+ tests|^\[e2e\]|XCTAssert|Timed out' .build/test.log | cut -c1-500
exit $status
