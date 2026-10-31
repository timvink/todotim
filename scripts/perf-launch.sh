#!/usr/bin/env bash
# Times app launches: runs the release binary RUNS times in the launch-only perf mode
# (TODOTIM_PERF_LAUNCH=1: the app does not activate, sync is off, it quits once the launch has
# settled) and prints the median, minimum and maximum of every field of its LAUNCH line
# (milliseconds; points in time are since process start, see Sources/TodoTim/Perf.swift).
# Usage: scripts/perf-launch.sh DATA_DIR [RUNS]
#   DATA_DIR  scratch database directory; without db.json the database is empty. Never the real one.
#   RUNS      timed launches (default 12), after one untimed warm-up launch.
# Env: BIN           binary to run (default: release build in SCRATCH_PATH)
#      SCRATCH_PATH  build directory (default .build-perf)
#      SEED=large    seed an empty DATA_DIR with the 5,000-task fixture during the warm-up launch
#      LOG           also append the raw LAUNCH lines to this file
set -euo pipefail
cd "$(dirname "$0")/.."
DATA_DIR="${1:?usage: scripts/perf-launch.sh DATA_DIR [RUNS]}"
RUNS="${2:-12}"
mkdir -p "$DATA_DIR"
REAL_DIR="$HOME/Library/Application Support/TodoTim"
if [[ -d "$REAL_DIR" && "$(cd "$DATA_DIR" && pwd -P)" == "$(cd "$REAL_DIR" && pwd -P)" ]]; then
    echo "perf-launch: refusing to use the real data directory" >&2
    exit 1
fi
if [[ -z "${BIN:-}" ]]; then
    SCRATCH_PATH="${SCRATCH_PATH:-.build-perf}"
    swift build -c release --scratch-path "$SCRATCH_PATH" >&2
    BIN="$(swift build -c release --scratch-path "$SCRATCH_PATH" --show-bin-path)/TodoTim"
fi

launch() {
    TODOTIM_DATA_DIR="$DATA_DIR" TODOTIM_PERF=1 TODOTIM_PERF_LAUNCH=1 "$@" timeout 60 "$BIN" 2>&1 \
        | sed -n 's/^\[perf\] t=[0-9.]*s LAUNCH //p' || true
}

launch env ${SEED:+TODOTIM_SEED=$SEED} >/dev/null   # warm-up (and seeding), not reported
LINES="$(mktemp -t todotim-launch)"
trap 'rm -f "$LINES"' EXIT
for _ in $(seq "$RUNS"); do launch env >>"$LINES"; done
if [[ -n "${LOG:-}" ]]; then cat "$LINES" >>"$LOG"; fi
echo "$(wc -l <"$LINES" | tr -d ' ') launches of $BIN with $DATA_DIR"

# One "key value" line per field, then median / min / max per key (in first-seen order).
tr ' ' '\n' <"$LINES" | awk -F= 'NF == 2 { if (!($1 in seen)) { seen[$1] = 1; order[++n] = $1 } print $1, $2 }
    END { for (i = 1; i <= n; i++) print "#order", order[i] }' >"$LINES.kv"
trap 'rm -f "$LINES" "$LINES.kv"' EXIT
grep '^#order ' "$LINES.kv" | while read -r _ key; do
    grep "^$key " "$LINES.kv" | cut -d' ' -f2 | sort -n | awk -v key="$key" '
        { v[NR] = $1 }
        END { m = NR % 2 ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
              printf "%-22s median %9.1f   min %9.1f   max %9.1f\n", key, m, v[1], v[NR] }'
done
