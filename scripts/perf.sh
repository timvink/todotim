#!/usr/bin/env bash
# Builds an optimised binary with the perf script compiled in (-DTODOTIM_PERF_SCRIPT; normal
# release bundles do not contain it) and runs the scripted performance pass, printing the [perf] log.
# Usage: scripts/perf.sh
# Env: DATA_DIR      scratch database directory (default $TMPDIR/todotim-perf); seeded with the
#                    5,000-task fixture on first run. Sync is off and no config file is read.
#      SCRATCH_PATH  build directory (default .build-perf)
# The app does not activate itself in this mode and only posts events to its own queue.
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH_PATH="${SCRATCH_PATH:-.build-perf}"
DATA_DIR="${DATA_DIR:-${TMPDIR:-/tmp}/todotim-perf}"
FLAGS=(-c release --scratch-path "$SCRATCH_PATH" -Xswiftc -DTODOTIM_PERF_SCRIPT)
swift build "${FLAGS[@]}" >&2
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/TodoTim"
mkdir -p "$DATA_DIR"
run() {
    TODOTIM_DATA_DIR="$DATA_DIR" TODOTIM_PERF=1 TODOTIM_PERF_SCRIPT=1 "$@" timeout 600 "$BIN" 2>&1 | grep '^\[perf\]' || true
}
if [[ ! -f "$DATA_DIR/db.json" ]]; then
    run env TODOTIM_SEED=large >/dev/null   # seeding run, not reported
fi
run env
