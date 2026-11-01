# TodoTim

Native macOS (15+) Todoist clone in SwiftUI, syncing with any CalDAV server (VTODO), such as Nextcloud or Radicale.
No calendar, board, Today or Upcoming views.

## Layout

- `Sources/TodoCore` — models, `TodoStore` (all mutations), persistence, parsing, CalDAV sync. No UI.
- `Sources/TodoTim` — SwiftUI app.
- `Tests/TodoCoreTests` — XCTest for TodoCore.
- `scripts/bundle.sh` — builds `build/TodoTim.app` from the SwiftPM executable.

## Build and test

    swift build
    swift test
    scripts/bundle.sh && open build/TodoTim.app

When several agents work at once, use a private scratch path: `swift build --scratch-path .build-<name>`.

TodoCore and its tests also build on Linux (the app target is left out there), for example with
`docker run --rm -v "$PWD":/src -w /src swift:6.2 swift test --scratch-path .build-linux`. Keychain and
`password_command` are macOS-only. Linux XCTest crashes on synchronous test methods in `@MainActor` classes,
so make them `async` in a scratch copy when running the whole suite there.

Live sync test against a real CalDAV server (use a throwaway user; it deletes that user's task lists):
`TODOTIM_LIVE_URL=https://host/remote.php/dav/ TODOTIM_LIVE_USER=… TODOTIM_LIVE_PASSWORD=… [TODOTIM_LIVE_SHARE_WITH=…] swift test --filter LiveCalDAVTests`.
`TODOTIM_LIVE_SHARE_WITH` needs Nextcloud. Throwaway local servers work too (http is allowed for localhost):
Radicale (`uvx --from radicale radicale --config <file>` with an htpasswd user and `owner_only` rights, or the
`tomsquest/docker-radicale` image; `TODOTIM_LIVE_URL=http://localhost:5232/`) and Xandikos
(`uvx xandikos serve -d <dir> --defaults -p 8237`, no auth; `TODOTIM_LIVE_URL=http://localhost:8237/`).

## Data model

- Projects, sections, tasks (subtasks via `parentId`), labels. The inbox is a project with id `inbox`.
- Every entity has `updatedAt` + `deleted` (tombstone). Mutate only via `TodoStore` so `updatedAt` is bumped.
- Sibling order is a `Double` `order`; inserts take the midpoint, and siblings are renumbered when gaps run out.
- `TodoStore` keeps indexes (children, areas, counts) and fine-grained observation: iterate `taskIDs`/`subtaskIDs`
  and read `store.task(id)` per row so a content edit redraws one row. Use `structureVersion` as a cache key.
- Local saves go through `PersistenceWriter` (background, coalesced). A corrupt `db.json` is moved aside, never overwritten.
  Loading tries `DatabaseDecoder` (strict byte-level fast path) first; whatever it declines goes to `JSONDecoder`,
  which alone decides whether the file is corrupt. Keep both in step when the model's `Codable` fields change.
- Due dates are local calendar dates (`yyyy-MM-dd`), no time.

## Sync

Local-first: `~/Library/Application Support/TodoTim/db.json`. The server side is any CalDAV server with
VTODO, mapped in [docs/caldav.md](docs/caldav.md) (the contract shared with other clients and the tasks MCP
server; change both together): project = VTODO-only calendar (inbox = `todotim-inbox`), task = VTODO,
sections and labels = dead properties on the calendars plus `X-TODOTIM-SECTION` parameters and `CATEGORIES`
on tasks.

- `WebDAVClient` — HTTP with the security rules; `CalDAVClient` — the CalDAV requests (`CalDAVServer`
  protocol; tests use `FakeCalDAVServer`, whose `FakeDAVLayout` also answers discovery over a stub
  URLProtocol); `Multistatus` — bounded 207 parser.
- `CalDAVDiscovery` — finds the calendar home: `current-user-principal` on the server URL, else on
  `/.well-known/caldav`, then the principal's `calendar-home-set`; without them `calendars/<username>/` (the
  SabreDAV layout, as before discovery). The home is kept in `CalDAVState.home`; `SyncController` discovers
  again only on a 404/403 from the home, or for another server URL or username (a new state). A changed
  home starts a fresh state (merge by id, nothing deleted).
- `ICalendar` — bounded RFC 5545 parser/serializer; `VTodo` — `TodoTask` ↔ VTODO. Writes patch only the
  owned properties that changed, so other clients' properties survive. `Recurrence` — RRULE advance.
- `CalDAVSync` — one sync: PROPFIND the home, `sync-collection` REPORT per calendar whose sync token moved,
  three-way merge of local / server / base (`CalDAVState`, saved as `caldav-state.json`), then conditional
  writes (MKCALENDAR, PROPPATCH, PUT, MOVE, DELETE). A 412 skips the write, and the next pass (at most 3)
  re-fetches and merges. `SyncEngine` holds the database rules: last-writer-wins, `sanitize`, tombstone purge,
  `repairStructure`, and `rebase` for local edits made during a sync.
- Server differences `CalDAVClient` absorbs: objects that sync-collection reports without `calendar-data`
  (Xandikos) are fetched with `calendar-multiget`; a calendar without `sync-token` uses `getctag` and a
  `calendar-query` (token prefix `ctag:`); optional properties a PROPPATCH refuses (Xandikos: `sections`,
  `labels`) are kept in `CalDAVState.refusedProperties` and not sent again (sections and labels then come
  from the tasks); a refused MKCALENDAR is retried with only name and component set; 423 Locked (Xandikos,
  during concurrent writes) is retried in `WebDAVClient`.
- `SyncController` — settings, Keychain, loop. It saves the state only after the database is on disk
  (`flushDatabase`): the state must never describe a newer database than the one stored. The app creates it
  with `startSyncing: false` and calls `start()` after the first frame; the Keychain read and the state file
  load run off the main actor.

Merge: if only one side changed since the base, that side wins. If both changed, tasks are
last-writer-wins on `updatedAt` ↔ `LAST-MODIFIED` (whole seconds on the server), and project, section and
label fields keep the local value. Nothing is deleted on the server without a local tombstone. A local edit
is a difference from `CalDAVState.synced` (each task as the database held it after the last sync), not from
the parsed object. After a write the local copy takes the server's fields (second precision), so the next
sync sees no change. After merging, `SyncEngine.repairStructure` fixes parent cycles, orphaned subtasks and
tasks in deleted sections. That repair is local only: a write keeps the server's parent, section and list
unless the user changed them. Tombstones are purged after 30 days, except while the server still has the
entity. A sync with refused or conflicting writes is `isComplete == false`, and the next one is never
treated as idle.

Nextcloud quirks: `calendars/<user>/inbox/` is the scheduling inbox (hence `todotim-inbox`; scheduling
inboxes and outboxes are skipped by `resourcetype` on every server); `calendar-order` is stored as an integer
(projects are renumbered 1…N); dead properties sent with MKCALENDAR are dropped (PROPPATCH after it) and are
per user (sharees can't read `sections`, hence the task parameters); deleted calendars go to a trash bin
that blocks MKCALENDAR at the same path; compressing reverse proxies rewrite ETags
(`WebDAVClient.normalizeETag` undoes that); the owner check on `oc:owner-principal` compares with the
discovered principal (the login name can differ from the user id); `share_with` uses Nextcloud's sharing
(elsewhere it fails as a sync warning).

Remote data is untrusted: ids and references must pass `isValidEntityID` (`[A-Za-z0-9_-]{1,64}`, otherwise
derived as UUID v5), calendar data and XML are parsed with bounds, and `SyncLimits` bounds responses,
counts, text and depth. `WebDAVClient` refuses http:// (except localhost), dot segments, and requests,
redirects and hrefs outside its allowed root: the DAV root, or the calendar home itself when discovery
finds the home outside the DAV root. Discovery stays on the server URL's origin and refuses a principal,
home or redirect elsewhere (`SyncError.otherServer`, e.g. iCloud). Hrefs must be direct children of the
home or calendar.

Performance benchmarks: `swift test -c release -Xswiftc -enable-testing --filter PerformanceTests`.
In the app: `scripts/perf-launch.sh DATA_DIR` (launch timing, medians) and `scripts/perf.sh` (scripted interactions).
Password is stored in the Keychain under `SyncSettings.credentialAccount` (`user@host[:port]`); the settings in
UserDefaults. `~/.todotim.toml` is only read when owned by the user and not group/world-writable (`AppConfig.load`).

## Android app (`android/`)

Kotlin + Jetpack Compose companion app (sideloaded, single user), Gradle rooted at `android/`. It follows
the same contract ([docs/caldav.md](docs/caldav.md)). Shared golden data lives in `fixtures/` at the repo
root; both the Swift tests and the Kotlin tests check against it, so a contract change updates both.

- `android/core` — pure Kotlin/JVM (no Android APIs): models, iCalendar, VTODO mapping, recurrence,
  quick add, CalDAV client, sync, store. Package `app.todotim.core`.
- `android/app` — Compose UI, WorkManager background sync, credentials. Package `app.todotim.android`.
  The UI reads core's `Snapshot` and mutates core's `TodoStore` directly (no repository layer); edit tasks
  with `store.edit(id) { it.copy(…) }`, which hands over the stored task, never a display-repaired snapshot
  copy. `TodoTimApplication` owns one `AppGraph`: the store (loaded off the main thread from
  `filesDir/todotim/db.json`), persistence, `SyncSettingsStore` (URL and username in SharedPreferences, the
  password AES-GCM-encrypted with an Android Keystore key) and the one `SyncManager` that the UI (start,
  resume after 1 min, pull-to-refresh, 3 s after edits) and the 15-minute `SyncWorker` share.

    cd android && ./gradlew :core:test            # JVM tests, incl. fixtures
    cd android && ./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease

Release builds are minified (R8) and signed with `android/keystore.properties` (gitignored; `storeFile`
relative to `android/`, `storePassword`, `keyAlias`, `keyPassword`) when present, else with the debug key.

Needs JDK 21 (`JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home` on the Mac) and an
Android SDK in `android/local.properties` (`sdk.dir=…`).

Live tests (same env vars and throwaway account as the Swift live test): the phone's sync alone,
`./gradlew :core:test --tests app.todotim.core.sync.LiveCalDAVTest`; the Mac and the phone taking turns on one
account and checking each other's changes (incl. both syncing at once), `scripts/live-interop.sh` (Swift
`CrossClientLiveTests` + Kotlin `CrossClientLiveTest`; `SWIFT_SCRATCH` sets the Swift scratch path).
