# TodoTim

Native macOS (15+) Todoist clone in SwiftUI, syncing to a Nextcloud WebDAV folder.
No calendar, board, Today or Upcoming views.

## Layout

- `Sources/TodoCore` — models, `TodoStore` (all mutations), persistence, parsing, WebDAV sync. No UI.
- `Sources/TodoTim` — SwiftUI app.
- `Tests/TodoCoreTests` — XCTest for TodoCore.
- `scripts/bundle.sh` — builds `build/TodoTim.app` from the SwiftPM executable.

## Build and test

    swift build
    swift test
    scripts/bundle.sh && open build/TodoTim.app

When several agents work at once, use a private scratch path: `swift build --scratch-path .build-<name>`.

## Data model

- Projects, sections, tasks (subtasks via `parentId`), labels. The inbox is a project with id `inbox`.
- Every entity has `updatedAt` + `deleted` (tombstone). Mutate only via `TodoStore` so `updatedAt` is bumped.
- Sibling order is a `Double` `order`; inserts take the midpoint, and siblings are renumbered when gaps run out.
- `TodoStore` keeps indexes (children, areas, counts) and fine-grained observation: iterate `taskIDs`/`subtaskIDs`
  and read `store.task(id)` per row so a content edit redraws one row. Use `structureVersion` as a cache key.
- Local saves go through `PersistenceWriter` (background, coalesced). A corrupt `db.json` is moved aside, never overwritten.
- Due dates are local calendar dates (`yyyy-MM-dd`), no time.

## Sync

Local-first: `~/Library/Application Support/TodoTim/db.json`. Remote layout in the configured folder:

- `index.json` — `{ "schemaVersion": 1, "projects": [...], "labels": [...] }`
- `projects/<projectId>.json` — `{ "schemaVersion": 1, "projectId", "sections": [...], "tasks": [...] }`

Sync downloads all files, merges every entity globally by id (newer `updatedAt` wins; on a tie
`deleted` wins), re-partitions by `projectId`, and uploads files whose content changed using
`If-Match` ETags (retry on 412). After merging, `SyncEngine.repairStructure` fixes parent cycles, orphaned
subtasks and tasks in deleted sections. Tombstones older than 30 days are purged.

Remote data is untrusted: ids and references must pass `isValidEntityID` (`[A-Za-z0-9_-]{1,64}`); invalid
entities are dropped in `SyncEngine.sanitize`, and `SyncLimits` bounds responses, file counts, text and depth.
`WebDAVClient` refuses http:// (except localhost), dot segments and redirects outside the base URL.

Performance benchmarks: `swift test -c release -Xswiftc -enable-testing --filter PerformanceTests`.
Password is stored in the Keychain under `SyncSettings.credentialAccount` (`user@host[:port]`); the settings in
UserDefaults. `~/.todotim.toml` is only read when owned by the user and not group/world-writable (`AppConfig.load`).
