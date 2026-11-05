#!/usr/bin/env bash
# Runs the Swift tests (TodoCore and the Linux engine) on Linux. Linux XCTest crashes while listing
# synchronous test methods of @MainActor classes, so the tests run from a scratch copy in which the
# `func testX()` of files with @MainActor are made `async`. Arguments go to `swift test` (for example
# `--filter Engine`).
#
# It runs itself in the swift:6.2.4 Docker image (the toolchain of scripts/linux-build.sh), with its
# build cache in the `todotim-swift-linux` volume.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${TODOTIM_IN_CONTAINER:-}" != 1 ]]; then
  exec docker run --rm -e TODOTIM_IN_CONTAINER=1 -v "$repo":/src:ro -v todotim-swift-linux:/build -w /src \
    swift:6.2.4 bash /src/scripts/linux-test.sh "$@"
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cp -R "$repo/Package.swift" "$repo/Sources" "$repo/Tests" "$repo/fixtures" "$scratch/"
grep -rl --include='*.swift' '@MainActor' "$scratch/Tests" | xargs -r \
  sed -E -i 's/^([[:space:]]*)func (test[A-Za-z0-9_]*)\(\)( throws)? \{/\1func \2() async throws {/'

build="${SWIFT_SCRATCH:-/build/linux-test}"
[[ -d /build ]] || build="$scratch/.build"
swift test --package-path "$scratch" --scratch-path "$build" "$@"
