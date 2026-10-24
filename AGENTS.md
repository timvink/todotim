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
- Sibling order is a `Double` `order`; inserts take the midpoint.
- Due dates are local calendar dates (`yyyy-MM-dd`), no time.

## Sync

Local-first: `~/Library/Application Support/TodoTim/db.json`. Remote layout in the configured folder:

- `index.json` — `{ "schemaVersion": 1, "projects": [...], "labels": [...] }`
- `projects/<projectId>.json` — `{ "schemaVersion": 1, "projectId", "sections": [...], "tasks": [...] }`

Sync downloads all files, merges every entity globally by id (newer `updatedAt` wins; on a tie
`deleted` wins), re-partitions by `projectId`, and uploads files whose content changed using
`If-Match` ETags (retry on 412). Tombstones older than 30 days are purged.
Password is stored in the Keychain; the settings in UserDefaults.
