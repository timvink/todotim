# Contributing

## Development setup

Requirements: macOS 15 or later and Xcode 26 (Swift 6.2). There are no third-party dependencies.

    git clone git@github.com:timvink/todotim.git
    cd todotim
    swift build
    swift test
    scripts/bundle.sh && open build/TodoTim.app

To try the app without touching your real data, point it at a scratch data directory and seed sample data:

    TODOTIM_DATA_DIR=/tmp/todotim-dev TODOTIM_SEED=1 build/TodoTim.app/Contents/MacOS/TodoTim

See `AGENTS.md` for the architecture, data model and sync format.

## Pull requests

- Keep changes focused; one feature or fix per pull request.
- Put logic in `TodoCore` with tests; keep `TodoTim` (SwiftUI) thin.
- Change data only through `TodoStore`, so `updatedAt` is bumped and sync picks the change up.
- Changes to the remote file format must stay readable by the previous release, or bump `schemaVersion` and migrate.
- CI must pass: `swift build`, `swift test` and `scripts/bundle.sh`.

## Releases

Releases are built by GitHub Actions (`.github/workflows/release.yml`) when a version tag is pushed.

1. Make sure `main` is green.
2. Pick the next [semantic version](https://semver.org), for example `v0.2.0`.
3. Tag and push:

       git tag -a v0.2.0 -m "v0.2.0"
       git push origin v0.2.0

4. The workflow runs the tests, builds a universal (Apple silicon + Intel) `TodoTim.app`, and publishes
   `TodoTim-v0.2.0.zip` plus a SHA-256 checksum on a GitHub release with generated notes.
5. Edit the release notes on GitHub if needed.

The app is ad-hoc signed, not notarized. On first launch, users right-click the app and choose **Open**,
or run `xattr -dr com.apple.quarantine /Applications/TodoTim.app`.

## Dependency audit

`.github/workflows/dependency-audit.yml` runs on the 1st and 15th of each month. It checks Swift package
updates and open Dependabot alerts, and opens an issue when something needs attention. Dependabot also
proposes updates for GitHub Actions.
