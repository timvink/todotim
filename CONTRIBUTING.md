# Contributing

## Build from source

The Mac app needs macOS 15 or later and Xcode 26 (Swift 6.2), with no third-party dependencies:

    git clone git@github.com:timvink/todotim.git
    cd todotim
    swift build
    swift test
    scripts/bundle.sh && open build/TodoTim.app

To try the app without touching your real data, point it at a scratch data directory and seed sample data:

    TODOTIM_DATA_DIR=/tmp/todotim-dev TODOTIM_SEED=1 build/TodoTim.app/Contents/MacOS/TodoTim

The Android app is a Gradle project in `android/` (JDK 21 and the Android SDK):

    cd android && ./gradlew :core:test :app:assembleDebug

The Omarchy app is the QML plugin in `linux/omarchy-plugin` and the `todotim-engine` Swift executable. Its scripts
run in Docker, so they work from a Mac too; [docs/linux.md](docs/linux.md) covers developing it:

    scripts/linux-test.sh                  # TodoCore and engine tests on Linux
    scripts/linux-build.sh                 # static engines in build/linux/<arch>/

See [AGENTS.md](AGENTS.md) for the architecture, data model and sync format.

## Pull requests

- Keep changes focused; one feature or fix per pull request.
- Put logic in `TodoCore` with tests; keep `TodoTim` (SwiftUI) thin.
- Change data only through `TodoStore`, so `updatedAt` is bumped and sync picks the change up.
- Changes to the remote file format must stay readable by the previous release, or bump `schemaVersion` and migrate.
- CI must pass: `swift build`, `swift test` and `scripts/bundle.sh` on macOS, and `scripts/linux-test.sh` plus
  the static engine build on Linux.

## Releases

Releases are built by GitHub Actions (`.github/workflows/release.yml`) when a version tag is pushed. Each app
has its own versions and releases:

| Tag | Release | Files |
|---|---|---|
| `macos-vX.Y.Z` | TodoTim for macOS X.Y.Z | `TodoTim-macOS-X.Y.Z.zip` |
| `android-vX.Y.Z` | TodoTim for Android X.Y.Z | `TodoTim-Android-X.Y.Z.apk` |
| `linux-vX.Y.Z` | TodoTim for Omarchy X.Y.Z | `todotim-omarchy-X.Y.Z-x86_64.tar.gz`, `-aarch64.tar.gz` |

Each file has a `.sha256` next to it. (Up to v0.9.1, one `vX.Y.Z` tag released the Mac and Android apps
together.)

1. Make sure `main` is green.
2. Pick the app's next [semantic version](https://semver.org) (the Android `versionCode` comes from it, so it
   only goes up).
3. Tag and push, for example:

       git tag -a linux-v0.1.0 -m "TodoTim for Omarchy 0.1.0"
       git push origin linux-v0.1.0

4. The `tag` job reads the app and version from the tag. Only that app's build job runs, with a read-only token:
   - `build-macos` runs the tests, builds a universal (Apple silicon + Intel) `TodoTim.app`, signs it (see below)
     and zips it.
   - `build-android` runs the Android tests and builds the signed release APK; it fails without the signing
     secrets.
   - `build-linux` runs the Linux tests (`scripts/linux-test.sh`), builds the static engines for x86_64 and
     aarch64 (`scripts/linux-build.sh`), checks them, and packs the tarballs (`scripts/linux-package.sh`).
   The `publish` job (no checkout, no repository code) attests the build provenance of the files and creates the
   GitHub release, with notes since the app's previous release.
5. Edit the release notes on GitHub if needed.

Users verify a download with `gh attestation verify <file> --repo timvink/todotim`.

The Mac app is signed with the hardened runtime (`scripts/bundle.sh`). When the repository has the signing
secrets, the build job signs it with a Developer ID, notarizes and staples it; without them it is ad-hoc signed,
and on first launch users approve it in **System Settings › Privacy & Security › Open Anyway** (don't tell them
to remove the quarantine attribute). The APK is always signed with the one release key. See
[docs/signing.md](docs/signing.md) for both setups.

Workflow actions are pinned to full commit SHAs with a `# vX.Y.Z` comment; Dependabot proposes updates.

## Dependency audit

`.github/workflows/dependency-audit.yml` runs on the 1st and 15th of each month. It checks Swift package
updates and open Dependabot alerts, and opens an issue when something needs attention (unless an open
"Dependency audit" issue exists). The workflow token usually cannot read Dependabot alerts; the run then shows a
warning and relies on Dependabot's own alert notifications. Dependabot also
proposes updates for GitHub Actions.
