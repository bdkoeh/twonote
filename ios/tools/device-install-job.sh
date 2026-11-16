#!/bin/bash
# Runs device-install.sh inside the logged-in desktop session (so signing can reach the
# keychain) and waits for it. Runs on the Mac. Same arguments as device-install.sh; the
# iPhone's id goes in TWONOTE_DEVICE, as there:
#
#   TWONOTE_DEVICE=<device id> tools/device-install-job.sh TwoNote TwoNote
#
# The log is ios/.build/device-install.log.
set -uo pipefail
LABEL=com.twonote.deviceinstall
IOS="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$IOS/tools"
mkdir -p "$IOS/.build"
LOG="$IOS/.build/device-install.log"
PLIST="$IOS/.build/$LABEL.plist"
[ -n "${TWONOTE_DEVICE:-}" ] || { echo "set TWONOTE_DEVICE to the iPhone's id (xcrun devicectl list devices)"; exit 1; }
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
: > "$LOG"
cat > "$PLIST" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$TOOLS/device-install.sh</string><string>$1</string><string>$2</string><string>${3:-}</string></array>
<key>EnvironmentVariables</key><dict><key>TWONOTE_DEVICE</key><string>$TWONOTE_DEVICE</string></dict>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>$LOG</string>
<key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
P
launchctl bootstrap "gui/$(id -u)" "$PLIST" || { echo "could not start the job"; exit 1; }
for _ in $(seq 1 "${TWONOTE_JOB_WAIT:-240}"); do
  grep -q "^RESULT:" "$LOG" && break
  sleep 5
done
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$PLIST"
cat "$LOG"
grep -q "^RESULT: installed" "$LOG"
