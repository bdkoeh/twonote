#!/bin/bash
# Runs a command inside the logged-in desktop session of the Mac (launchd's gui/<uid> domain)
# and waits for it, printing its output. Runs on the Mac. Needed for everything that signs
# (the signing key is out of reach of SSH sessions: errSecInternalComponent) and for UI tests
# (they need the window server). The same pattern as device-install-job.sh.
#
#   tools/gui-job.sh <name> <command> [args...]
#
# The command runs with /bin/bash from the ios/ directory this script is in; the job's exit
# status is the command's. Its log is ios/.build/job-<name>.log. TWONOTE_JOB_WAIT is the
# longest wait in seconds (default 3600).
set -uo pipefail
NAME="$1"; shift
LABEL="com.twonote.job.$NAME"
IOS="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$IOS/.build"
mkdir -p "$BUILD"
LOG="$BUILD/job-$NAME.log"
PLIST="$BUILD/$LABEL.plist"
SCRIPT="$BUILD/job-$NAME.sh"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
: > "$LOG"
{
  echo '#!/bin/bash'
  echo 'export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"'
  printf 'cd %q || exit 1\n' "$IOS"
  printf '%q ' "$@"
  echo
  echo 'echo "RESULT: $?"'
} > "$SCRIPT"
cat > "$PLIST" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$SCRIPT</string></array>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>$LOG</string>
<key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
P
launchctl bootstrap "gui/$(id -u)" "$PLIST" || { echo "could not start the job"; exit 1; }
waited=0
limit="${TWONOTE_JOB_WAIT:-3600}"
printed=0
while [ "$waited" -lt "$limit" ]; do
  # Pass the output on as it comes.
  lines=$(wc -l < "$LOG" | tr -d ' ')
  if [ "$lines" -gt "$printed" ]; then
    tail -n +"$((printed + 1))" "$LOG" | head -n "$((lines - printed))"
    printed=$lines
  fi
  grep -q "^RESULT: " "$LOG" && break
  sleep 3
  waited=$((waited + 3))
done
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
lines=$(wc -l < "$LOG" | tr -d ' ')
[ "$lines" -gt "$printed" ] && tail -n +"$((printed + 1))" "$LOG"
rm -f "$PLIST" "$SCRIPT"
status=$(grep "^RESULT: " "$LOG" | tail -1 | sed 's/RESULT: //')
[ -n "$status" ] || { echo "the job did not finish within ${limit}s"; exit 124; }
exit "$status"
