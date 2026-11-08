#!/usr/bin/env bash
# Installs TodoTim for Omarchy from this release folder: the plugin and its engine go to
# ~/.config/omarchy/plugins/timvink.todotim, and the plugin is enabled in the running shell.
# Run it again to update; your tasks (~/.local/share/todotim) are kept.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
id="timvink.todotim"
plugins="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
dest="$plugins/$id"

if ! command -v omarchy-shell > /dev/null; then
  echo "TodoTim needs Omarchy 4 or later (its Quickshell desktop); omarchy-shell was not found." >&2
  exit 1
fi

engine_arch="$(cat "$here/ARCH" 2>/dev/null || echo unknown)"
machine="$(uname -m)"
[[ "$machine" == arm64 ]] && machine=aarch64
if [[ "$engine_arch" != "$machine" ]]; then
  echo "This release is for $engine_arch, but this machine is $machine. Download the $machine release." >&2
  exit 1
fi
if ! "$here/bin/todotim-engine" --version > /dev/null; then
  echo "The bundled todotim-engine does not run on this machine." >&2
  exit 1
fi
command -v secret-tool > /dev/null || echo "Note: secret-tool (pacman -S libsecret) stores the sync password in your keyring."

# Stage next to the destination under a hidden name (the shell ignores those), then swap, so the
# shell never loads a half-copied plugin.
mkdir -p "$plugins"
stage="$plugins/.$id.new"
rm -rf "$stage" "$plugins/.$id.old"
cp -R "$here/plugin" "$stage"
mkdir -p "$stage/bin"
cp "$here/bin/todotim-engine" "$stage/bin/todotim-engine"
chmod 755 "$stage/bin/todotim-engine"
updating=0
if [[ -e "$dest" ]]; then
  updating=1
  mv "$dest" "$plugins/.$id.old"
fi
mv "$stage" "$dest"
rm -rf "$plugins/.$id.old"

# TodoTim has no bar widget; versions up to 0.1.2 put one on the bar, so move such an entry
# from bar.layout to the plugins list, which keeps the plugin enabled without a spot on the bar.
shell_config="$(readlink -f "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json" 2> /dev/null || true)"
if [[ -n "$shell_config" && -f "$shell_config" ]] && command -v jq > /dev/null; then
  migrated="$(mktemp "$shell_config.todotim.XXXXXX")"
  if jq --arg id "$id" '
      def mine: type == "object" and .id == $id;
      if [(.bar.layout // {})[]? | arrays | .[] | select(mine)] | length > 0 then
        .bar.layout |= map_values(if type == "array" then map(select(mine | not)) else . end)
        | .plugins = ((.plugins // []) | if any(.[]; mine) then . else . + [{id: $id}] end)
      else empty end' "$shell_config" > "$migrated" && [[ -s "$migrated" ]]; then
    chmod --reference="$shell_config" "$migrated"
    mv "$migrated" "$shell_config"
    omarchy-shell -q shell reloadConfig > /dev/null || true
    echo "Removed TodoTim from the bar (it stays enabled)."
  else
    rm -f "$migrated"
  fi
fi

# The shell reloads an installed plugin's code by itself; a new one needs a rescan, which runs in
# the background, so enabling is retried until the shell knows the plugin. Without a bar widget,
# enabling adds it to shell.json's plugins list, not to the bar.
omarchy-shell -q shell rescanPlugins
if (( ! updating )); then
  enabled=0
  for _ in $(seq 20); do
    if omarchy plugin enable "$id" > /dev/null 2>&1; then
      enabled=1
      break
    fi
    sleep 0.5
  done
  (( enabled )) || echo "Could not enable the plugin; run: omarchy plugin enable $id" >&2
fi

version="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$dest/manifest.json" | head -n1)"
if (( updating )); then
  echo "Updated TodoTim to $version."
else
  cat <<EOF
Installed TodoTim $version.

Open it with:   omarchy-shell shell toggle $id
Bind a key in ~/.config/hypr/bindings.lua, for example:

  o.bind("SUPER + ALT + T", "TodoTim", { panel = "$id" })
  o.bind("SUPER + ALT + Q", "TodoTim Quick Add", "omarchy-shell shell summon $id '{\"action\":\"quickAdd\"}'")

Sync: open TodoTim and press Ctrl+, (or use ~/.todotim.toml, as on the Mac).
EOF
fi
