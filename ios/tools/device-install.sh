#!/bin/bash
# Builds, signs and installs the iOS app on a paired iPhone. Runs on the Mac.
#
#   TWONOTE_DEVICE=<device id> tools/device-install.sh TwoNote TwoNote
#
# <device id> is the iPhone's identifier as `xcrun devicectl list devices` shows it. The team
# and bundle ids come from Config/Local.xcconfig (DEVELOPMENT_TEAM, TWONOTE_BUNDLE_PREFIX); the
# team has to be set there, and the iPhone registered in that team's account (automatic signing
# with -allowProvisioningUpdates does that the first time).
# Signing needs the login keychain, which is locked for SSH sessions: over SSH run this through
# device-install-job.sh, which starts it inside the logged-in desktop session.
# Usage: device-install.sh <project dir under ios/> <scheme> [bundle id to launch]
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"
IOS="$(cd "$(dirname "$0")/.." && pwd)"
. "$IOS/tools/config.sh"
DIR="$IOS/$1"; SCHEME="$2"; BUNDLE="${3:-$TWONOTE_IOS_BUNDLE_ID}"
DEVICE="${TWONOTE_DEVICE:-}"
[ -n "$DEVICE" ] || { echo "RESULT: set TWONOTE_DEVICE to the iPhone's id (xcrun devicectl list devices)"; exit 1; }
[ -n "$TWONOTE_TEAM" ] || { echo "RESULT: no team: set DEVELOPMENT_TEAM in Config/Local.xcconfig (copy Local.xcconfig.example)"; exit 1; }
cd "$DIR" || { echo "RESULT: no such dir $DIR"; exit 1; }
xcodegen >/dev/null || { echo "RESULT: xcodegen failed"; exit 1; }
xcodebuild build -project "$SCHEME.xcodeproj" -scheme "$SCHEME" \
  -destination "platform=iOS,id=$DEVICE" -derivedDataPath .build/device -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)|errSec" | tail -n 20
[ "${PIPESTATUS[0]}" = 0 ] || { echo "RESULT: build failed"; exit 1; }
APP=$(find .build/device/Build/Products/Debug-iphoneos -maxdepth 1 -name "*.app" | head -1)
xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1 | grep -E "App installed|bundleID|ERROR|Reason" | head -5
[ "${PIPESTATUS[0]}" = 0 ] || { echo "RESULT: install failed"; exit 1; }
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" 2>&1 | tail -n 2
echo "RESULT: installed"
