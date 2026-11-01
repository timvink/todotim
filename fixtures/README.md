# Shared fixtures

Golden data checked by both the Swift tests (`Tests/TodoCoreTests/FixtureTests.swift`) and the Kotlin
tests (`android/core/src/test`). A behaviour change updates the fixture and both implementations together.
All dates are ISO `yyyy-MM-dd` local calendar dates. Locales are identifiers such as `en_US`.

## recurrence

`recurrence.json`: `Recurrence.advance` and `Recurrence.summary` (RRULE handling, see
[docs/caldav.md](../docs/caldav.md) "Repeating tasks").

- `zone`: the user's timezone for every case (a UTC `UNTIL` is read as a local date in it).
- `advance`: list of cases
  - `rrule`: the RRULE value as stored on the task.
  - `due`: the task's due date, or `null` (the next date then counts from `today`).
  - `today`: the user's local date when the task is completed.
  - `expected`: either `{ "due": "yyyy-MM-dd", "rrule": "…" }` (the task moves to that date and
    stores that rule) or the string `"complete"` (unsupported rule or series ended: complete the task).
  - `note`: free text, for failure messages.
- `summary`: list of `{ "rrule", "expected" }`, the UI label (`"Every 2 weeks"`, `"Repeats"`).

## quickadd

`quickadd.json`: `QuickAddParser` (English).

- `today`, `todayWeekday`, `locale`: defaults for every case. `todayWeekday` is informational; tests
  assert that it matches `today`.
- `cases`: list of
  - `input`: the quick-add line.
  - optional `today`, `locale`: overrides (the locale decides `5/1` day/month order).
  - optional `projects`, `sections`: known names passed to the parser (default empty).
  - `expected`: the parsed task. Missing fields take the default: `content` (required), `due`
    (`null`), `priority` (1–4 for p1–p4, or `null` when none was typed), `labels` (`[]`, in order,
    deduplicated case-insensitively), `project` and `section` (`null`; the name as the parser returns
    it: the known name's spelling, or the word as typed), `noDate` (`false`).
  - optional `tokens`: the recognised tokens in text order, each `{ "kind", "text" }` with kind one of
    `priority`, `label`, `project`, `section`, `date` and `text` the exact substring of `input`
    (a date token includes a leading "on"/"by"/"due").

## dates

`dates.json`: `DateParser` and due-date display (`DueDate.displayString`, `daysFromToday`,
`isOverdue` in Swift; `DueDateFormatting` in Kotlin).

- `today`, `todayWeekday`, `locale`: defaults, as in `quickadd.json`.
- `parse`: list of `{ "input", "expected", optional "today", optional "locale" }`, where `input` is
  a whole date phrase (`DateParser.parsePhrase`) and `expected` is a date, `"noDate"` for "no date"
  phrases, or `null` when the text is not a date phrase.
- `dayFirst`: list of `{ "locale", "expected" }`: whether the locale writes numeric dates day first.
- `display`: list of `{ "date", "expected", optional "today" }`: the label ("Today", "Friday",
  "Nov 3", "Nov 3 2027").
- `relative`: list of `{ "date", "days", "overdue" }` relative to `today`: whole days from today
  (negative = past) and whether the date is overdue.

## palette

`palette.json`: `ProjectColor`.

- `entries`: the 20 palette entries in order, `{ "key", "name", "hex" }` with `hex` as `#RRGGBB`
  (uppercase).
- `lookup`: `{ "input", "key", "hex" }`: the entry a stored color name resolves to (name
  normalisation: case, spaces, underscores, "mint"; anything else is charcoal) and its hex.
- `nearest`: `{ "hex", "key" }`: the palette key nearest to a CalDAV color (`#RRGGBB` or
  `#RRGGBBAA`, alpha ignored, surrounding spaces trimmed) by the weighted distance
  2·Δr² + 4·Δg² + 3·Δb² (the first entry wins a tie), or `null` when the text is not a hex color.

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

**`numbers.json`.** `format`: `{ "value", "text" }`, how an order is written in `X-TODOTIM-ORDER` and
`X-ORDER` (`VTodo.format`): a whole number below 10^15 without a fraction, otherwise Swift's
`Double.description` (`1e-05`, `1000000000000000.0`, `1e+16`). `value` is a string, parsed as a Double.

**`make/<name>.json` + `make/<name>.ics`.** `VTodo.make(task, uid:, parentUID:, section:)` must return the
`.ics`. The JSON holds `task` (a task object, without `uid`, `sectionName` and `sectionOrder`), `uid`,
`parentUid` (string or null) and `section` (as in `edit.json`, or null).

## urls

`urls.json`: the URL rules of `WebDAVClient` (docs/caldav.md, "Limits"): what a server URL may be, how a
relative path becomes a request URL, and which hrefs from a server are accepted.

- `baseURL`: `normalizedBaseURL`.
  - `valid`: `{ "input", "normalized" }`; the input is accepted and normalized to that URL (trailing slash).
    Scheme and host compare in lowercase: Foundation keeps their spelling, OkHttp lowercases them.
  - `insecure`: plain http:// to a host other than localhost; refused as insecure.
  - `invalid`: refused as an invalid URL (no scheme or host, credentials, query, fragment, other schemes).
- `requestPath`: `url(for:)` on a client with server URL `base`.
  - `encoded`: `{ "path", "collection", "url" }`; the path (decoded, relative to `base`) gives that URL.
  - `refused`: paths with empty, "." or ".." segments; refused without sending a request.
- `href`: `relativePath(ofHref:)` on a client with server URL `base`: `{ "href", "path" }`, where `path` is the
  decoded path relative to `base`, or `null` when the href is refused (another origin, outside `base`, a
  segment that is or decodes to "." or "..", or one that decodes to "/").
