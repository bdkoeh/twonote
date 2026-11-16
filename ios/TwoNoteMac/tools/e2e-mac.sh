#!/bin/bash
# The end-to-end run: the real Mac app (Debug build, signed with its provisioning profile,
# sandboxed, real Keychain, real App Group, its share extension) against a fresh server
# container, with a second device in the app's process. Run on the Mac:
#
#   TwoNoteMac/tools/e2e-mac.sh                 run, screenshots into TwoNoteMac/shots
#   TWONOTE_SHOTS= TwoNoteMac/tools/e2e-mac.sh  run without screenshots
#   TwoNoteMac/tools/e2e-mac.sh migration       the Keychain migration run: an M1-style sign-in
#                                               (login keychain), then an ordinary launch that
#                                               must have moved it and still be signed in
#
# The run is driven from inside the app (Sources/Debug/EndToEndDriver*.swift): XCUITest needs
# macOS "automation mode", which an administrator has to confirm on screen first. With that
# done once on this Mac, TWONOTE_E2E_XCUITEST=1 runs the XCUITest version
# (UITests/EndToEndTests.swift) instead.
#
# The Debug build has the installed app's bundle id (<prefix>.mac, from ../Config), so it
# shares its sandbox container, its Keychain items and its App Group, and the run wipes them. It therefore refuses to start
# while TwoNote on this Mac is signed in to an account (a store, a server address, or an item
# in the login keychain).
#
# Starts its own container (twonote-mac-e2e on 127.0.0.1:18190, image twonote-server:latest)
# and its helper (tools/e2e-mac-control.py on 127.0.0.1:18191: stops and starts the container,
# receives progress and screenshots), and removes both afterwards; touches no other container.
# The app and signing need the desktop session, so over SSH the run hands itself to
# tools/gui-job.sh and waits. The app's own data is wiped at the end of the run, and the build
# is taken out of Launch Services again, so that its share extension and widget do not linger
# in the Share menu and the widget gallery beside the installed app's.
cd "$(dirname "$0")/.." || exit 1
if [ -z "$TWONOTE_IN_GUI_JOB" ] && [ -n "$SSH_CONNECTION" ]; then
  exec env TWONOTE_JOB_WAIT="${TWONOTE_JOB_WAIT:-3600}" bash ../tools/gui-job.sh mace2e \
    env TWONOTE_IN_GUI_JOB=1 TWONOTE_SHOTS="${TWONOTE_SHOTS-$PWD/shots}" TWONOTE_E2E_XCUITEST="${TWONOTE_E2E_XCUITEST:-}" \
    bash TwoNoteMac/tools/e2e-mac.sh "$@"
fi
export PATH="/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
. ../tools/config.sh
mode=${1:-full}
[ -n "$TWONOTE_BUNDLE_PREFIX" ] || { echo "[e2e] no TWONOTE_BUNDLE_PREFIX in ../Config: not running"; exit 2; }
data="$HOME/Library/Containers/$TWONOTE_MAC_BUNDLE_ID/Data"
if [ -e "$data/Library/Application Support/TwoNote/store.db" ] \
   || defaults read "$data/Library/Preferences/$TWONOTE_MAC_BUNDLE_ID" server.url > /dev/null 2>&1 \
   || security find-generic-password -s TwoNote > /dev/null 2>&1; then
  echo "[e2e] TwoNote on this Mac is signed in (or a run was cut short): not running, the run would wipe that."
  echo "[e2e] Sign out in TwoNote > Settings > Account first."
  exit 2
fi
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
name=twonote-mac-e2e
port=18190
control=18191
shots=${TWONOTE_SHOTS-$PWD/shots}
mkdir -p .build
result_file="$PWD/.build/e2e-result"
rm -f "$result_file"

docker rm -f "$name" > /dev/null 2>&1
docker run -d --name "$name" -p "127.0.0.1:$port:8080" twonote-server:latest > /dev/null || { echo "[e2e] docker run failed"; exit 1; }
[ -n "$shots" ] && mkdir -p "$shots"
# The stand-in for another app's Share menu (see tools/e2e-mac-share.swift).
swiftc -O -o .build/e2e-mac-share tools/e2e-mac-share.swift > .build/e2e-share-build.log 2>&1   || { echo "[e2e] the share helper did not build"; cat .build/e2e-share-build.log; exit 1; }
python3 tools/e2e-mac-control.py "$name" "$control" "$shots" "$result_file" "$PWD/.build/e2e-mac-share" &
helper=$!
app_pid=
app_bundle="$PWD/.build/xcode/Build/Products/Debug/TwoNote.app"
app_binary="$app_bundle/Contents/MacOS/TwoNote"
cleanup() {
  [ -n "$app_pid" ] && kill $app_pid 2>/dev/null
  pkill -f "^$app_binary" 2>/dev/null
  kill $helper 2>/dev/null
  docker rm -f "$name" > /dev/null 2>&1
  for x in Share Widget; do pluginkit -r "$app_bundle/Contents/PlugIns/TwoNoteMac$x.appex" 2>/dev/null; done
  "$lsregister" -u "$app_bundle" 2>/dev/null
}
trap cleanup EXIT
for _ in $(seq 1 30); do
  curl -s -m 2 "http://127.0.0.1:$port/api/v1/status" > /dev/null && break
  sleep 1
done
curl -s -m 2 "http://127.0.0.1:$port/api/v1/status" > /dev/null || { echo "[e2e] the server did not come up"; exit 1; }

if [ -n "$TWONOTE_E2E_XCUITEST" ]; then
  export TEST_RUNNER_TWONOTE_E2E_URL="http://127.0.0.1:$port"
  export TEST_RUNNER_TWONOTE_E2E_CONTROL="http://127.0.0.1:$control"
  export TEST_RUNNER_TWONOTE_SHOTS_DIR="$shots"
  TWONOTE_IN_GUI_JOB=1 bash tools/test-mac.sh -only-testing:TwoNoteMacUITests "$@"
  exit $?
fi

xcodegen > .build/xcodegen.log 2>&1 || { cat .build/xcodegen.log; exit 1; }
xcodebuild build -project TwoNoteMac.xcodeproj -scheme TwoNoteMac -configuration Debug \
  -destination "platform=macOS,arch=arm64" -derivedDataPath .build/xcode > .build/e2e-build.log 2>&1 \
  || { grep -E "error:|BUILD" .build/e2e-build.log | head -20; exit 1; }
app=.build/xcode/Build/Products/Debug/TwoNote.app
echo "[e2e] built $(codesign -dvv "$app" 2>&1 | grep -E '^Authority=' | head -1)"

# The share extension, so that the Share menu offers it to the run (the build registered the
# app with Launch Services; this makes sure the extension is known before the app asks).
pluginkit -a "$app/Contents/PlugIns/TwoNoteMacShare.appex" 2>/dev/null
echo "[e2e] share extension: $(pluginkit -m -v -i "$TWONOTE_MAC_BUNDLE_ID.share" 2>&1 | tr -s ' \t' ' ' | head -3 | tr '\n' ' ')"

# One launch of the app, through Launch Services (`open`), as from the Finder: started
# directly, the app would get no "open application" event and SwiftUI would open no window.
launch() {
  rm -f "$result_file"
  : > .build/e2e-app.log
  open -n -W --stdout "$PWD/.build/e2e-app.log" --stderr "$PWD/.build/e2e-app.log" "$app" --args "$@" \
    -TwoNoteE2E "http://127.0.0.1:$port" -TwoNoteE2EControl "http://127.0.0.1:$control" \
    -ApplePersistenceIgnoreState YES &
  app_pid=$!
  limit=${TWONOTE_E2E_LIMIT:-900}
  for _ in $(seq 1 "$limit"); do
    kill -0 "$app_pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$app_pid" 2>/dev/null; then
    echo "[e2e] the app did not finish within ${limit}s"
    kill "$app_pid"
    pkill -f "^$app_binary"
  fi
  app_pid=
  result=$(cat "$result_file" 2>/dev/null)
  echo "[e2e] result: ${result:-none (see .build/e2e-app.log)}"
  grep -iE "fatal|crash|error" .build/e2e-app.log | grep -v "^\[e2e\]" | head -10
  [ "$result" = "passed" ]
}

if [ "$mode" = "migration" ]; then
  launch -TwoNoteResetState YES -TwoNoteE2EMode legacy-enrol -TwoNoteLoginKeychainOnly YES || exit 1
  launch -TwoNoteE2EMode migrate-check
else
  launch -TwoNoteResetState YES
fi
