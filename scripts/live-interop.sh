#!/bin/bash
# Cross-client live test: the Mac's sync (Swift, CrossClientLiveTests) and the phone's (Kotlin, CrossClientLiveTest)
# take turns on one real CalDAV account and check each other's changes. Destructive for the account's task lists:
# use a throwaway user.
#
#   TODOTIM_LIVE_URL=http://localhost:5232/ TODOTIM_LIVE_USER=tim TODOTIM_LIVE_PASSWORD=secret scripts/live-interop.sh
#
# SWIFT_SCRATCH sets `swift test --scratch-path` (default .build). The Kotlin steps need JAVA_HOME (JDK 21) and
# android/local.properties, as for `./gradlew :core:test`.
set -euo pipefail

: "${TODOTIM_LIVE_URL:?set TODOTIM_LIVE_URL}" "${TODOTIM_LIVE_USER:?set TODOTIM_LIVE_USER}" "${TODOTIM_LIVE_PASSWORD:?set TODOTIM_LIVE_PASSWORD}"
export TODOTIM_LIVE_URL TODOTIM_LIVE_USER TODOTIM_LIVE_PASSWORD

root="$(cd "$(dirname "$0")/.." && pwd)"
TODOTIM_CROSS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/todotim-interop.XXXXXX")"
export TODOTIM_CROSS_DIR
fail() { echo "$1 (logs and state: $TODOTIM_CROSS_DIR)"; exit 1; }
scratch="${SWIFT_SCRATCH:-$root/.build}"

# The phone runs only its own steps; skipped tests count as passed, so check that the step really ran.
mac() {
  echo "== Mac step $1"
  (cd "$root" && TODOTIM_CROSS_STEP="$1" swift test --scratch-path "$scratch" --filter CrossClientLiveTests 2>&1) \
    | tee "$TODOTIM_CROSS_DIR/mac-$1.log" | grep -E "error|failed|passed|skipped" || true
  grep -q "Executed 1 test, with 0 failures" "$TODOTIM_CROSS_DIR/mac-$1.log" || fail "Mac step $1 failed"
  ! grep -q "Test skipped" "$TODOTIM_CROSS_DIR/mac-$1.log" || fail "Mac step $1 was skipped"
}

phone() {
  echo "== Phone step $1"
  local report="$root/android/core/build/test-results/test/TEST-app.todotim.core.sync.CrossClientLiveTest.xml"
  rm -f "$report"
  local status=0
  (cd "$root/android" && TODOTIM_CROSS_STEP="$1" ./gradlew :core:test --tests app.todotim.core.sync.CrossClientLiveTest \
    --no-daemon -q >"$TODOTIM_CROSS_DIR/phone-$1.log" 2>&1) || status=$?
  cp "$report" "$TODOTIM_CROSS_DIR/phone-$1.xml" 2>/dev/null || true
  [ "$status" = 0 ] || fail "Phone step $1 failed"
  grep -q 'skipped="0"' "$report" && grep -q 'failures="0"' "$report" || fail "Phone step $1 was skipped"
}

mac a    # the Mac makes lists, sections, labels and tasks; another client adds a property and an alarm
phone b  # the phone reads exactly that, then edits, completes, adds, moves and deletes
mac c    # the Mac sees all of it; it completes "Gym" without syncing
phone d1 # the phone completes "Gym" and syncs, then completes "Take out bins" without syncing
mac d2   # the Mac completes "Take out bins" and syncs
phone d3 # the phone syncs: each repeating task advanced once
mac d4   # the Mac agrees with the phone on every task
echo "== Mac and phone agree"
rm -rf "$TODOTIM_CROSS_DIR"
