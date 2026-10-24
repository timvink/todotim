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

4. The `build` job (read-only token) checks that the tag looks like `vX.Y.Z`, runs the tests, builds a
   universal (Apple silicon + Intel) `TodoTim.app`, and uploads `TodoTim-v0.2.0.zip` plus a SHA-256 checksum
   as a workflow artifact. The `publish` job (no checkout, no repository code) attests the zip's build
   provenance and creates the GitHub release with generated notes.
5. Edit the release notes on GitHub if needed.

Users verify a download with `gh attestation verify TodoTim-v0.2.0.zip --repo timvink/todotim`.

The app is ad-hoc signed with the hardened runtime (`scripts/bundle.sh`), not Developer ID signed or
notarized. On first launch users approve it in **System Settings › Privacy & Security › Open Anyway**; don't
tell them to remove the quarantine attribute. Developer ID signing and notarization would be better, but need
a paid Apple Developer account.

Workflow actions are pinned to full commit SHAs with a `# vX.Y.Z` comment; Dependabot proposes updates.

## Dependency audit

`.github/workflows/dependency-audit.yml` runs on the 1st and 15th of each month. It checks Swift package
updates and open Dependabot alerts, and opens an issue when something needs attention (unless an open
"Dependency audit" issue exists). The workflow token usually cannot read Dependabot alerts; the run then shows a
warning and relies on Dependabot's own alert notifications. Dependabot also
proposes updates for GitHub Actions.
