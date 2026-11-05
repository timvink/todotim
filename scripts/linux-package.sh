#!/usr/bin/env bash
# Packs the Omarchy release: dist/todotim-omarchy-<version>-<arch>.tar.gz (+ .sha256) for each
# architecture built by scripts/linux-build.sh. Each tarball holds the plugin (with the version in
# its manifest), the static engine, install.sh, uninstall.sh, README.md and LICENSE.
# Usage: VERSION=1.2.3 scripts/linux-package.sh
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:?set VERSION, e.g. 0.1.0}"
ARCHS="${ARCHS:-x86_64 aarch64}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must look like 1.2.3" >&2
  exit 1
fi

mkdir -p "$repo/dist"
for arch in $ARCHS; do
  engine="$repo/build/linux/$arch/todotim-engine"
  [[ -x "$engine" ]] || { echo "missing $engine; run scripts/linux-build.sh first" >&2; exit 1; }
  name="todotim-omarchy-$VERSION-$arch"
  stage="$(mktemp -d)/$name"
  mkdir -p "$stage/bin"
  cp -R "$repo/linux/omarchy-plugin" "$stage/plugin"
  sed -i.bak "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" "$stage/plugin/manifest.json"
  rm -f "$stage/plugin/manifest.json.bak"
  cp "$engine" "$stage/bin/todotim-engine"
  cp "$repo/linux/install.sh" "$repo/linux/uninstall.sh" "$repo/LICENSE" "$stage/"
  cp "$repo/linux/RELEASE-README.md" "$stage/README.md"
  echo "$arch" > "$stage/ARCH"
  chmod 755 "$stage/install.sh" "$stage/uninstall.sh" "$stage/bin/todotim-engine"
  # Reproducible archive: fixed owner, sorted names and the commit time.
  mtime="$(git -C "$repo" log -1 --format=%ct 2>/dev/null || date +%s)"
  tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$mtime" \
    -C "$(dirname "$stage")" -czf "$repo/dist/$name.tar.gz" "$name"
  (cd "$repo/dist" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
  rm -rf "$(dirname "$stage")"
  echo "dist/$name.tar.gz"
done
