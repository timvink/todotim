# Shared fixtures

Golden data checked by both the Swift tests (`Tests/TodoCoreTests`) and the Kotlin tests
(`android/core/src/test`). A behaviour change updates the fixture and both implementations together.
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
