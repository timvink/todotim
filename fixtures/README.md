# Shared fixtures

Golden data that both the Swift tests (`Tests/TodoCoreTests`) and the Kotlin tests (`android/core`) check, so
the macOS and Android apps follow the same contract ([docs/caldav.md](../docs/caldav.md)). A change to the
contract updates the fixtures, and both test suites with them. Each section below belongs to one area.

## vtodo

The VTODO ↔ task mapping (`VTodo` in Swift and in `app.todotim.core.ical`). Every case uses project id `p`
and the timezone `Europe/Amsterdam`. The `.ics` files are compared byte for byte (CRLF, folding), so
`vtodo/.gitattributes` turns off line-ending conversion. Swift's `VTodo.patch` uses `Calendar.current` for
due-date moves, so a Swift runner sets `NSTimeZone.default` to Europe/Amsterdam; Kotlin passes the zone.

**Task JSON.** A task is an object with all of these keys (`null` where absent):

| Key | Type | Notes |
|---|---|---|
| `id`, `projectId` | string | |
| `sectionId`, `parentId` | string or null | |
| `content`, `description` | string | |
| `priority` | 1–4 | p1 … p4 |
| `due` | `"yyyy-MM-dd"` or null | |
| `labels` | array of strings | |
| `isCompleted`, `collapsed` | boolean | |
| `completedAt` | time or null | |
| `order` | number | |
| `recurrence` | string or null | RRULE value |
| `createdAt`, `updatedAt` | time | |

A time is UTC ISO 8601 in whole seconds: `"2026-11-01T12:00:00Z"`. Numbers compare as numbers (`12` = `12.0`).

**`read/<name>.ics` + `read/<name>.json`.** The JSON is the result of `VTodo.read(ics, projectId: "p")`: a
task object plus `uid` (string), `sectionName` (string or null) and `sectionOrder` (number or null). `null`
means the object is not a task (read returns nil).

**`patch/<name>.before.ics` + `<name>.edit.json` + `<name>.after.ics`.** Read `before.ics` as above, change
the task, call `VTodo.patch(before, old: <read result>, to: <changed task>, parentUID:, section:)`, and compare
the result with `after.ics`. `edit.json`:

```json
{
  "set": { "due": "2026-11-08", "recurrence": "FREQ=WEEKLY;COUNT=2" },
  "parentUid": "new-parent",
  "section": { "id": "s1", "name": "Errands", "order": 2.5 },
  "unchanged": true
}
```

- `set`: task fields to change, with the keys and types of the task JSON. `updatedAt` defaults to the fixed
  "now" `2027-01-15T08:00:00Z` (it is set before `set` is applied).
- `parentUid` (optional): the parent UID to write. Default: the changed task's `parentId`.
- `section` (optional, object or null): the task's section. Default: when the changed task has a `sectionId`,
  that id with the read `sectionName` and `sectionOrder` (`""` and `0` when missing); else null.
- `unchanged: true`: patch must return nil (nothing to write); there is no `after.ics`.

**`make/<name>.json` + `make/<name>.ics`.** `VTodo.make(task, uid:, parentUID:, section:)` must return the
`.ics`. The JSON holds `task` (a task object, without `uid`, `sectionName` and `sectionOrder`), `uid`,
`parentUid` (string or null) and `section` (as in `edit.json`, or null).
