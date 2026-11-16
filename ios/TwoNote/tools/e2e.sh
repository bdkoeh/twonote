#!/bin/bash
# The end-to-end run: the real app in the simulator against a fresh server container, with a
# second device in the test process (UITests/EndToEndTests.swift). Run on the Mac:
#
#   tools/e2e.sh                 run, screenshots into ./shots
#   TWONOTE_SHOTS= tools/e2e.sh  run without screenshots (faster)
#   TWONOTE_ONLY=TwoNoteUITests/ExtrasEndToEndTests tools/e2e.sh
#                                only the share extension, links and widget run (it starts
#                                from a fresh server itself; EndToEndTests is the main run)
#
# Starts its own container (twonote-ios-app-e2e on port 18090, image twonote-server:latest)
# and removes it afterwards; touches no other container.
cd "$(dirname "$0")/.." || exit 1
name=twonote-ios-app-e2e
port=18090
control=18091
shots=${TWONOTE_SHOTS-$PWD/shots}

docker rm -f "$name" > /dev/null 2>&1
docker run -d --name "$name" -p "$port:8080" twonote-server:latest > /dev/null || exit 1
python3 tools/e2e-control.py "$name" "$control" "$port" twonote-server:latest &
helper=$!
trap 'kill $helper 2>/dev/null; docker rm -f "$name" > /dev/null 2>&1' EXIT
for _ in $(seq 1 30); do
  curl -s -m 2 "http://127.0.0.1:$port/api/v1/status" > /dev/null && break
  sleep 1
done
[ -n "$shots" ] && mkdir -p "$shots"

TEST_RUNNER_TWONOTE_E2E_URL="http://127.0.0.1:$port" \
TEST_RUNNER_TWONOTE_E2E_CONTROL="http://127.0.0.1:$control" \
TEST_RUNNER_TWONOTE_SHOTS_DIR="$shots" \
  tools/test.sh "-only-testing:${TWONOTE_ONLY:-TwoNoteUITests}" "$@"
