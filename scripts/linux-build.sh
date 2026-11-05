#!/usr/bin/env bash
# Builds todotim-engine for Linux as one fully static binary per architecture (Swift's Static Linux
# SDK, musl): no shared libraries, so the same file runs on Arch (Omarchy) and any other distribution.
# Output: build/linux/<arch>/todotim-engine for each of $ARCHS (default "x86_64 aarch64").
# $VERSION (default "dev") is what `todotim-engine --version` prints.
#
# It runs itself in the Swift Docker image below (SDK and build cache in the `todotim-swift-static` volume).
set -euo pipefail

# Swift 6.2: FoundationNetworking in 6.4.2 crashes on Linux when a URLSession goes away
# ("_MultiHandle deallocated with non-zero retain count").
SWIFT_IMAGE="swift:6.2.4"
# Verified against its PGP signature (Swift 6.x Release Signing Key, 52BB 7E3D E28A 71BE 22EC 05FF EF80 A866 B47A 981F).
SDK_URL="https://download.swift.org/swift-6.2.4-release/static-sdk/swift-6.2.4-RELEASE/swift-6.2.4-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz"
SDK_SHA256="24bdf84495dd31a6de2eb679647c1982b747bfbfe1a2060c779d84dcecd902a4"

repo="$(cd "$(dirname "$0")/.." && pwd)"
ARCHS="${ARCHS:-x86_64 aarch64}"
VERSION="${VERSION:-dev}"

if [[ "${TODOTIM_IN_CONTAINER:-}" != 1 ]]; then
  exec docker run --rm -e TODOTIM_IN_CONTAINER=1 -e ARCHS="$ARCHS" -e VERSION="$VERSION" \
    -v "$repo":/src -v todotim-swift-static:/cache -w /src "$SWIFT_IMAGE" bash /src/scripts/linux-build.sh
fi

if [[ ! "$VERSION" =~ ^(dev|[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  echo "VERSION must look like 1.2.3" >&2
  exit 1
fi

cache="${TODOTIM_BUILD_CACHE:-/cache}"
[[ -d "$cache" && -w "$cache" ]] || cache="$repo/.build-linux-static"
sdks="$cache/swift-sdks"
mkdir -p "$sdks"
if ! swift sdk list --swift-sdks-path "$sdks" 2>/dev/null | grep -q static-linux; then
  # Downloaded with curl and checked here (`swift sdk install <url>` crashes in SwiftPM on Linux, the same FoundationNetworking bug).
  archive="$cache/$(basename "$SDK_URL")"
  if [[ ! -f "$archive" ]]; then
    curl -fsSL -o "$archive.part" "$SDK_URL"
    mv "$archive.part" "$archive"
  fi
  echo "$SDK_SHA256  $archive" | sha256sum -c -
  swift sdk install "$archive" --swift-sdks-path "$sdks"
fi

# A copy of the sources with the version stamped in, so the checkout is never modified.
src="$(mktemp -d)"
trap 'rm -rf "$src"' EXIT
cp -R "$repo/Package.swift" "$repo/Sources" "$repo/Tests" "$src/"
sed -i "s/public static let current = \"dev\"/public static let current = \"$VERSION\"/" "$src/Sources/TodoTimEngine/Version.swift"

for arch in $ARCHS; do
  args=(--package-path "$src" -c release --product todotim-engine --swift-sdks-path "$sdks"
        --swift-sdk "$arch-swift-linux-musl" --scratch-path "$cache/build-$arch")
  swift build "${args[@]}" -Xlinker -s
  bin="$(swift build "${args[@]}" --show-bin-path)"
  mkdir -p "$repo/build/linux/$arch"
  cp "$bin/todotim-engine" "$repo/build/linux/$arch/todotim-engine"
  echo "built build/linux/$arch/todotim-engine ($(du -h "$repo/build/linux/$arch/todotim-engine" | cut -f1))"
done
