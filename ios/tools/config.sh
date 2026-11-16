#!/bin/bash
# The identity the apps are built with, for the shell scripts: sourced, not run.
#
#   . "$(dirname "$0")/../../tools/config.sh"
#
# Reads DEVELOPMENT_TEAM and TWONOTE_BUNDLE_PREFIX from ../Config/TwoNote.xcconfig and then
# ../Config/Local.xcconfig if it exists (the later value wins, as in Xcode), and derives the
# same identifiers that file derives for the build. Only plain "KEY = value" lines of those two
# settings are read; keep them that way in Local.xcconfig.
_twonote_config_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../Config" && pwd)"

_twonote_config_value() { # <key>: the last value of <key> in the config files, or empty
  local key="$1" file value=""
  for file in "$_twonote_config_dir/TwoNote.xcconfig" "$_twonote_config_dir/Local.xcconfig"; do
    [ -f "$file" ] || continue
    local line
    line=$(sed -nE "s#^[[:space:]]*$key[[:space:]]*=[[:space:]]*([^/]*).*#\1#p" "$file" | tail -1)
    if grep -qE "^[[:space:]]*$key[[:space:]]*=" "$file"; then
      value="$(printf '%s' "$line" | sed -E 's/[[:space:]]+$//')"
    fi
  done
  printf '%s' "$value"
}

TWONOTE_TEAM="$(_twonote_config_value DEVELOPMENT_TEAM)"
TWONOTE_BUNDLE_PREFIX="$(_twonote_config_value TWONOTE_BUNDLE_PREFIX)"
TWONOTE_IOS_BUNDLE_ID="$TWONOTE_BUNDLE_PREFIX.app"
TWONOTE_IOS_APP_GROUP="group.$TWONOTE_IOS_BUNDLE_ID"
TWONOTE_MAC_BUNDLE_ID="$TWONOTE_BUNDLE_PREFIX.mac"
# Team-prefixed on the Mac; without a team the prefix is empty (see TwoNote.xcconfig).
TWONOTE_MAC_APP_GROUP="${TWONOTE_TEAM:+$TWONOTE_TEAM.}$TWONOTE_MAC_BUNDLE_ID"
unset -f _twonote_config_value
unset _twonote_config_dir
