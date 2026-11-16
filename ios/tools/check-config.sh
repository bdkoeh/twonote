#!/bin/bash
# Says which identity the projects are generated with, and what to do when no team is set.
# Run by xcodegen before it writes either project (preGenCommand in project.yml); never fails.
. "$(dirname "$0")/config.sh"
config="$(cd "$(dirname "$0")/../Config" && pwd)"
if [ -z "$TWONOTE_TEAM" ]; then
  if [ -f "$config/Local.xcconfig" ]; then where="Config/Local.xcconfig has no DEVELOPMENT_TEAM"
  else where="no Config/Local.xcconfig"; fi
  cat >&2 <<EOF
TwoNote: $where, so the projects use the defaults
  bundle prefix $TWONOTE_BUNDLE_PREFIX, no team: simulator builds and an ad hoc signed Mac app
  (no Touch ID, login keychain) only.
  For an iPhone or a signed Mac build: cp Config/Local.xcconfig.example Config/Local.xcconfig,
  set DEVELOPMENT_TEAM and TWONOTE_BUNDLE_PREFIX there, and run xcodegen again.
EOF
else
  echo "TwoNote: team $TWONOTE_TEAM, bundle prefix $TWONOTE_BUNDLE_PREFIX (Config/Local.xcconfig)" >&2
fi
exit 0
