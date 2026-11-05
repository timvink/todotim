#!/usr/bin/env bash
# Runs the TodoTim plugin in a headless sway session with a demo database, then runs a scenario
# (keys, theme switches, screenshots). For development and screenshots without an Omarchy machine;
# runs in the image from linux/dev/Dockerfile (Arch Linux with quickshell, sway, grim and wtype):
#
#   docker build -t todotim-qs linux/dev
#   docker run --rm -v "$PWD":/src -v /path/to/omarchy:/omarchy:ro -v /path/to/engine:/engine:ro \
#     -e OMARCHY_DIR=/omarchy -e TODOTIM_ENGINE_BIN=/engine/todotim-engine -e OUT_DIR=/src/build/shots \
#     todotim-qs bash /src/linux/dev/headless.sh /src/linux/dev/scenario.sh
#
# OMARCHY_DIR is an Omarchy checkout (its shell/Commons and shell/Ui stand in for the running shell,
# and its themes/ are switched between). A scenario is a bash file using `shot NAME`, `key ARGS…`
# (wtype arguments), `type TEXT`, `theme NAME` and `pause SECONDS`.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
: "${OMARCHY_DIR:?set OMARCHY_DIR to an Omarchy checkout}"
: "${TODOTIM_ENGINE_BIN:?set TODOTIM_ENGINE_BIN to a Linux todotim-engine}"
out="${OUT_DIR:-/tmp/todotim-shots}"
mkdir -p "$out"

export XDG_RUNTIME_DIR="$(mktemp -d)"
chmod 700 "$XDG_RUNTIME_DIR"
work="$(mktemp -d)"

# The harness config, with Omarchy's Commons/Ui as its qs.Commons and qs.Ui.
mkdir -p "$work/harness"
cp "$here/shell.qml" "$work/harness/"
ln -s "$OMARCHY_DIR/shell/Commons" "$work/harness/Commons"
ln -s "$OMARCHY_DIR/shell/Ui" "$work/harness/Ui"

# The active theme, where Omarchy keeps it.
theme_dir="$HOME/.local/state/omarchy/current/theme"
mkdir -p "$theme_dir"
cp "$OMARCHY_DIR/themes/${THEME:-tokyo-night}/colors.toml" "$theme_dir/colors.toml"

# Omarchy's monospace is a Nerd Font.
mkdir -p "$HOME/.config/fontconfig"
cat > "$HOME/.config/fontconfig/fonts.conf" <<'XML'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias><family>monospace</family><prefer><family>JetBrainsMono Nerd Font</family></prefer></alias>
</fontconfig>
XML

cat > "$work/engine" <<SH
#!/bin/sh
exec "$TODOTIM_ENGINE_BIN" --seed-demo --no-sync
SH
chmod +x "$work/engine"

cat > "$work/sway.conf" <<CONF
output HEADLESS-1 resolution ${WIDTH:-1400}x${HEIGHT:-900} scale ${SCALE:-1}
default_border none
gaps inner 0
CONF
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman sway -c "$work/sway.conf" > "$out/sway.log" 2>&1 &
sway_pid=$!
for _ in $(seq 50); do
  sock="$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v lock | head -n1 || true)"
  [[ -n "$sock" ]] && break
  sleep 0.1
done
export WAYLAND_DISPLAY="${sock##*/}"
export QT_QPA_PLATFORM=wayland

export TODOTIM_PLUGIN_DIR="$repo/linux/omarchy-plugin"
export TODOTIM_ENGINE="$work/engine"
export TODOTIM_DATA_DIR="$work/data"
export OMARCHY_THEMES="$OMARCHY_DIR/themes"
qs -p "$work/harness/shell.qml" > "$out/qs.log" 2>&1 &
qs_pid=$!
trap 'kill $qs_pid $sway_pid 2>/dev/null || true' EXIT

shot() { sleep "${SHOT_DELAY:-0.6}"; grim "$out/$1.png"; echo "shot $1"; }
# Every wtype run is a new virtual keyboard, and Qt drops the first event after a keymap change:
# a Shift tap absorbs it.
key() { wtype -k Shift_L -s 150 "$@"; sleep 0.3; }
type() { wtype -k Shift_L -s 150 -- "$1"; sleep 0.4; }
pause() { sleep "$1"; }
ipc() { qs -p "$work/harness/shell.qml" ipc call todotim "$@"; }
theme() {
  cp "$OMARCHY_DIR/themes/$1/colors.toml" "$theme_dir/colors.toml"
  ipc theme "$1" > /dev/null
  sleep 0.6
}

sleep "${STARTUP_DELAY:-4}"
if [[ $# -gt 0 ]]; then
  # shellcheck disable=SC1090
  source "$1"
else
  shot start
fi
echo "--- qs log"; grep -v '^\s*$' "$out/qs.log" | tail -n 40 || true
