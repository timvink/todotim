# TodoTim

Native macOS (15+) Todoist clone in SwiftUI, syncing with Nextcloud over CalDAV (VTODO).
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

Live sync test against a real Nextcloud (use a throwaway user; it deletes that user's task lists):
`TODOTIM_LIVE_URL=https://host/remote.php/dav/ TODOTIM_LIVE_USER=… TODOTIM_LIVE_PASSWORD=… [TODOTIM_LIVE_SHARE_WITH=…] swift test --filter LiveCalDAVTests`.

## Data model

- Projects, sections, tasks (subtasks via `parentId`), labels. The inbox is a project with id `inbox`.
- Every entity has `updatedAt` + `deleted` (tombstone). Mutate only via `TodoStore` so `updatedAt` is bumped.
- Sibling order is a `Double` `order`; inserts take the midpoint, and siblings are renumbered when gaps run out.
- `TodoStore` keeps indexes (children, areas, counts) and fine-grained observation: iterate `taskIDs`/`subtaskIDs`
  and read `store.task(id)` per row so a content edit redraws one row. Use `structureVersion` as a cache key.
- Local saves go through `PersistenceWriter` (background, coalesced). A corrupt `db.json` is moved aside, never overwritten.
- Due dates are local calendar dates (`yyyy-MM-dd`), no time.

## Sync

Local-first: `~/Library/Application Support/TodoTim/db.json`. The server side is CalDAV, mapped in
[docs/caldav.md](docs/caldav.md) (the contract shared with other clients and the tasks MCP server; change
both together): project = VTODO-only calendar (inbox = `todotim-inbox`), task = VTODO, sections and labels =
dead properties on the calendars plus `X-TODOTIM-SECTION` parameters and `CATEGORIES` on tasks.

- `WebDAVClient` — HTTP with the security rules; `CalDAVClient` — the CalDAV requests (`CalDAVServer`
  protocol; tests use `FakeCalDAVServer`); `Multistatus` — bounded 207 parser.
- `ICalendar` — bounded RFC 5545 parser/serializer; `VTodo` — `TodoTask` ↔ VTODO. Writes patch only the
  owned properties that changed, so other clients' properties survive. `Recurrence` — RRULE advance.
- `CalDAVSync` — one sync: PROPFIND the home, `sync-collection` REPORT per calendar whose sync token moved,
  three-way merge of local / server / base (`CalDAVState`, saved as `caldav-state.json`), then conditional
  writes (MKCALENDAR, PROPPATCH, PUT, MOVE, DELETE). A 412 skips the write, and the next pass (at most 3)
  re-fetches and merges. `SyncEngine` holds the database rules: last-writer-wins, `sanitize`, tombstone purge,
  `repairStructure`, and `rebase` for local edits made during a sync.
- `SyncController` — settings, Keychain, loop. It saves the state only after the database is on disk
  (`flushDatabase`): the state must never describe a newer database than the one stored.

Merge: if only one side changed since the base, that side wins. If both changed, tasks are
last-writer-wins on `updatedAt` ↔ `LAST-MODIFIED` (whole seconds on the server), and project, section and
label fields keep the local value. Nothing is deleted on the server without a local tombstone. A task synced
back from the server replaces the local copy (second precision), so the next sync sees no change. After
merging, `SyncEngine.repairStructure` fixes parent cycles, orphaned subtasks and tasks in deleted sections.
Tombstones are purged after 30 days, except while the server still has the entity.

Nextcloud quirks: `calendars/<user>/inbox/` is the scheduling inbox (hence `todotim-inbox`); `calendar-order`
is stored as an integer (projects are renumbered 1…N); dead properties sent with MKCALENDAR are dropped
(PROPPATCH after it) and are per user (sharees can't read `sections`, hence the task parameters); deleted
calendars go to a trash bin that blocks MKCALENDAR at the same path; compressing reverse proxies rewrite
ETags (`WebDAVClient.normalizeETag` undoes that).

Remote data is untrusted: ids and references must pass `isValidEntityID` (`[A-Za-z0-9_-]{1,64}`, otherwise
derived as UUID v5), calendar data and XML are parsed with bounds, and `SyncLimits` bounds responses,
counts, text and depth. `WebDAVClient` refuses http:// (except localhost), dot segments and redirects outside
the DAV root; hrefs must be direct children of the home or calendar.

Performance benchmarks: `swift test -c release -Xswiftc -enable-testing --filter PerformanceTests`.
Password is stored in the Keychain under `SyncSettings.credentialAccount` (`user@host[:port]`); the settings in
UserDefaults. `~/.todotim.toml` is only read when owned by the user and not group/world-writable (`AppConfig.load`).
