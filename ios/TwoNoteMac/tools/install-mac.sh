#!/bin/bash
# Builds the Mac app (Release, signed "Apple Development" with its provisioning profile,
# sandboxed, Hardened Runtime) with its share extension and widget, installs it as
# ~/Applications/TwoNote.app and opens it once. Run on the Mac:
#
#   bash TwoNoteMac/tools/install-mac.sh             build, install, open
#   TWONOTE_NO_OPEN=1 bash TwoNoteMac/tools/install-mac.sh
#
# Signing needs the desktop session's keychain, so over SSH the script hands itself to
# tools/gui-job.sh (a launchd job in gui/$(id -u)) and waits for it.
# The app's data stays where the app keeps it (~/Library/Containers/<prefix>.mac, the App
# Group container, the Keychain); a reinstall keeps it, and whoever is signed in stays signed
# in. A running copy is asked to quit first, the way Quit does it (it saves and locks).
cd "$(dirname "$0")/.." || exit 1
if [ -z "$TWONOTE_IN_GUI_JOB" ] && [ -n "$SSH_CONNECTION" ]; then
  exec bash ../tools/gui-job.sh macinstall \
    env TWONOTE_IN_GUI_JOB=1 TWONOTE_NO_OPEN="${TWONOTE_NO_OPEN:-}" bash TwoNoteMac/tools/install-mac.sh "$@"
fi
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
. ../tools/config.sh
[ -n "$TWONOTE_TEAM" ] || echo "[install] no DEVELOPMENT_TEAM in ../Config/Local.xcconfig: an ad hoc build, without Touch ID and the data-protection Keychain"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p .build
xcodegen > .build/xcodegen.log 2>&1 || { cat .build/xcodegen.log; exit 1; }
xcodebuild build -project TwoNoteMac.xcodeproj -scheme TwoNoteMac -configuration Release \
  -destination "platform=macOS,arch=arm64" -derivedDataPath .build/xcode > .build/install-build.log 2>&1 \
  || { grep -E "error:|BUILD" .build/install-build.log | head -20; exit 1; }
built=.build/xcode/Build/Products/Release/TwoNote.app
codesign --verify --strict --deep "$built" || { echo "[install] the build is not validly signed"; exit 1; }

target="$HOME/Applications/TwoNote.app"
binary="$target/Contents/MacOS/TwoNote"
if pgrep -f "^$binary" > /dev/null; then
  # Quit as the Quit command does (TwoNoteMacApp.swift listens for this Darwin notification
  # from stage M2 on): what was typed is saved and the app locks. A build from before that,
  # or one that does not answer, gets SIGTERM.
  notifyutil -p "$TWONOTE_MAC_APP_GROUP.quit"
  for _ in $(seq 1 30); do pgrep -f "^$binary" > /dev/null || break; sleep 0.5; done
  if pgrep -f "^$binary" > /dev/null; then
    echo "[install] TwoNote did not quit on request; sending SIGTERM"
    pkill -TERM -f "^$binary"
    for _ in $(seq 1 20); do pgrep -f "^$binary" > /dev/null || break; sleep 0.5; done
  else
    echo "[install] TwoNote quit"
  fi
fi
mkdir -p "$HOME/Applications"
rm -rf "$target"
ditto "$built" "$target"
echo "[install] installed $target"
codesign -dv "$target" 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier|Runtime Version)=" | head -4
for bundle in "$target" "$target"/Contents/PlugIns/*.appex; do
  echo "[install] entitlements of ${bundle#$HOME/}:"
  codesign -d --entitlements :- "$bundle" 2>/dev/null | plutil -p - | sed 's/^/    /'
done

# Only the installed copy in Launch Services: the build products are taken out again, so the
# Share menu, the widget gallery and twonote: links all go to ~/Applications/TwoNote.app.
for config in Debug Release; do
  product="$PWD/.build/xcode/Build/Products/$config/TwoNote.app"
  for x in Share Widget; do pluginkit -r "$product/Contents/PlugIns/TwoNoteMac$x.appex" 2>/dev/null; done
  "$lsregister" -u "$product" 2>/dev/null
done
"$lsregister" -f -R "$target"
for x in Share Widget; do pluginkit -a "$target/Contents/PlugIns/TwoNoteMac$x.appex"; done

if [ -z "$TWONOTE_NO_OPEN" ]; then
  open "$target" && sleep 4
  if pgrep -f "^$binary" > /dev/null; then
    echo "[install] TwoNote is running"
  else
    echo "[install] TwoNote did not start"; exit 1
  fi
fi
sleep 2
for id in "$TWONOTE_MAC_BUNDLE_ID.share" "$TWONOTE_MAC_BUNDLE_ID.widget"; do
  echo "[install] $(pluginkit -m -v -i $id 2>&1 | tr -s ' \t' ' ' | head -2 | tr '\n' ' ')"
done
echo "[install] twonote: links open $(osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL($.NSURL.URLWithString("twonote://new")).path.js' 2>&1)"
