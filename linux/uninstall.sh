#!/usr/bin/env bash
# Removes the TodoTim plugin from Omarchy. Your tasks and settings in ~/.local/share/todotim and the
# keyring entry stay unless you pass --purge.
set -euo pipefail

id="timvink.todotim"
dest="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$id"
data="${TODOTIM_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/todotim}"

if command -v omarchy-shell > /dev/null; then
  omarchy-shell -q shell hide "$id"
  omarchy plugin disable "$id" > /dev/null 2>&1 || true
fi
rm -rf "$dest"
rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/applications/todotim.desktop"
command -v omarchy-shell > /dev/null && omarchy-shell -q shell rescanPlugins
echo "Removed the TodoTim plugin."

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$data"
  if command -v secret-tool > /dev/null; then
    while secret-tool clear application todotim 2> /dev/null; do :; done
  fi
  echo "Deleted $data and the saved sync passwords."
else
  echo "Your tasks are still in $data (run with --purge to delete them)."
fi
