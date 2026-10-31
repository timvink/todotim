# CalDAV mapping

TodoTim stores its data as CalDAV to-dos (VTODO, [RFC 5545](https://www.rfc-editor.org/rfc/rfc5545)) in the
user's own calendars on a CalDAV server ([RFC 4791](https://www.rfc-editor.org/rfc/rfc4791)), such as
Nextcloud or Radicale. Any CalDAV task client, the Nextcloud Tasks app and the tasks MCP server read and
write the same objects, so this document is the contract between them. A client that follows it keeps
TodoTim's projects, sections, labels, subtasks and order intact. A client that ignores the TodoTim
properties still sees normal to-dos, and TodoTim keeps everything that client writes.

## Calendar home

`server_url` is the server's DAV root, for example `https://cloud.example.com/remote.php/dav/` (Nextcloud)
or `https://dav.example.com/` (Radicale). TodoTim finds the user's calendar home as
[RFC 6764](https://www.rfc-editor.org/rfc/rfc6764) (§6) and RFC 4791 (§6.2.1) describe:

1. `PROPFIND` (Depth 0) of `{DAV:}current-user-principal` on the server URL. When that names no
   principal, the same on `/.well-known/caldav` of the same origin. TodoTim follows redirects itself, one at
   a time (at most 5) and as PROPFIND.
2. `PROPFIND` (Depth 0) of `{urn:ietf:params:xml:ns:caldav}calendar-home-set` on that principal.

When neither gives a home, the home is `calendars/<username>/` below the server URL: the SabreDAV layout of
Nextcloud, ownCloud and Baïkal, and what TodoTim used before discovery. A wrong password (401) or a server
error (5xx, 429) stops discovery instead. Examples of homes: `remote.php/dav/calendars/<user>/` (Nextcloud),
`/<user>/` (Radicale), `/user/calendars/` (Xandikos).

TodoTim keeps the home in `caldav-state.json`, so a sync needs no discovery requests. It discovers again
when the home answers 404 or 403, and when the server URL or username changes. When the home changes, the
next sync starts from scratch: it matches lists and tasks by id and deletes nothing.

**Allowed root.** Discovery sends requests only to the server URL's origin (scheme, host and port). A
principal, home or redirect on another origin, such as iCloud's `pNN-caldav.icloud.com` hosts or a redirect
from https to http, is refused with an error that names it, and is not followed. Sync requests, redirects
and hrefs must stay inside the server URL when the home is inside it (Nextcloud: `remote.php/dav/`), and
otherwise inside the home itself (for example when `server_url` is a principal or a calendar). Below,
`<home>` stands for the calendar home.

## Projects: calendars

- A **project** is a calendar in the home whose `supported-calendar-component-set` is exactly `VTODO`.
  TodoTim ignores calendars that allow VEVENT (for example "Personal"), subscriptions, the scheduling
  inbox and outbox ([RFC 6638](https://www.rfc-editor.org/rfc/rfc6638), recognized by their
  `resourcetype`, whatever their name), calendars that other users share (Nextcloud lists them as
  `<uri>_shared_by_<owner>`, with an `{http://owncloud.org/ns}owner-principal` that is not the user's
  principal), and calendars that Nextcloud apps generate (`app-generated--…`, such as Deck boards). It
  syncs only the user's own calendars.
- **Project id** = the calendar URI (the last path segment) when it is a valid id
  (`[A-Za-z0-9_-]{1,64}`). Otherwise the id is a name-based UUID (v5) derived from the URI, and TodoTim keeps
  the mapping to the path. TodoTim creates a new project with MKCALENDAR at `<home>/<project id>/`, with a
  VTODO-only component set.
- **Inbox**: the calendar with URI **`todotim-inbox`** (display name "Inbox"). Its internal id is `inbox`.
  TodoTim creates it if it is missing. The URI cannot be `inbox`, because SabreDAV servers (Nextcloud,
  Baïkal) keep the CalDAV scheduling inbox at `<home>/inbox/`, which refuses MKCALENDAR.
- Calendar properties:

  | Project | Property | Notes |
  |---|---|---|
  | name | `{DAV:}displayname` | |
  | color | `{http://apple.com/ns/ical/}calendar-color` | Written as `#RRGGBB` (TodoTim's palette). `#RRGGBB` and `#RRGGBBAA` are read and mapped to the nearest palette color. On an existing calendar, TodoTim writes a color only when it is changed in TodoTim. |
  | order | `{http://apple.com/ns/ical/}calendar-order` | An **integer**: Nextcloud rounds anything else. TodoTim renumbers its lists 1…N before it writes when an order has a fraction, and writes the order only when it changes. The inbox always comes first; TodoTim gives it `0` when it creates it and does not sync its order after that. |
  | sections | `{https://todotim.app/ns}sections` | See below. |
  | labels | `{https://todotim.app/ns}labels` | Only on the inbox calendar. See below. |

- MKCALENDAR keeps the display name, color, order and component set. Nextcloud silently drops custom (dead)
  properties sent with MKCALENDAR, so TodoTim sets `sections` and `labels` with a PROPPATCH right after it.
  When a server refuses the MKCALENDAR (400, 403, 409, 415, 422 or 424), TodoTim tries once more with only
  the display name and the component set, and sets the color and order with PROPPATCH.
- **Servers without dead properties.** A server may refuse to store the color, order, `sections` or
  `labels` (Xandikos refuses `sections` and `labels` with 403). TodoTim then sends the rest again without
  them (servers that apply a PROPPATCH all or nothing answer 424 for the rest), remembers the refused
  properties in `caldav-state.json`, stops sending them, and shows a warning once. Sections then come from
  the tasks' `X-TODOTIM-SECTION` parameters and labels from `CATEGORIES`, as for a calendar shared with
  you: a section without tasks, and label colors and order, stay on the device that made them.
- **Sharing** (Nextcloud and ownCloud only): with `share_with = ["tasks-agent"]` in `[sync]`, TodoTim
  shares each calendar it creates, read-write, with every user in that list. It sends
  `POST <calendar path>` with Content-Type `application/xml` and this body:

  ```xml
  <o:share xmlns:d="DAV:" xmlns:o="http://owncloud.org/ns">
    <o:set><d:href>principal:principals/users/<name></d:href><o:read-write/></o:set>
  </o:share>
  ```

  This is best-effort: a failure, including a server without this extension, shows as a sync warning
  and does not stop the sync.
- **Deleting** a project deletes its calendar (DELETE on the collection; Nextcloud moves it to its trash
  bin). A calendar that disappears from the server deletes the project in TodoTim. The inbox is created
  again. A calendar still in Nextcloud's trash bin blocks MKCALENDAR at its path: TodoTim reports it and
  syncs the other lists.

## Sections

- The **authoritative list** is the dead property `{https://todotim.app/ns}sections` on the project's
  calendar: a JSON array `[{"id": "...", "name": "...", "order": 1.5}]`. Deleted sections are removed from
  the array, and empty sections are kept in it.
- Nextcloud stores dead properties **per user**, so a user the calendar is shared with (such as
  `tasks-agent`) gets 404 for this property. For that reason, every task in a section also carries the
  section's name and order (see `X-TODOTIM-SECTION` below).
- **Reading**: if the property exists (even as `[]`), it decides which sections exist and their names and
  orders. A task that refers to a section id not in the list has no section. If the property is missing
  (a calendar shared with you, or a new device before the property arrives), sections come from the tasks'
  `X-TODOTIM-SECTION` parameters, and the first task by path wins on name and order.
- **Writing**: when TodoTim renames or reorders a section, it rewrites the property and the
  `X-TODOTIM-SECTION` line of every task in that section. A client that files a task into an existing
  section copies `X-NAME`/`X-ORDER` from another task in it (or from the property, if it can read it).

## Labels

- Label metadata is the dead property `{https://todotim.app/ns}labels` on the **inbox** calendar:
  `[{"id": "...", "name": "...", "color": "#RRGGBB", "order": 1}]`. Like `sections`, it is readable only by
  the owner.
- A task's labels are its `CATEGORIES` (names, comma-separated, TEXT-escaped; several `CATEGORIES` lines
  are joined). A category that is not in the labels list becomes a label in TodoTim. Its id is derived from
  the name, so all devices create the same one.

## Tasks: VTODO objects

- **Task id** = `UID` when it is a valid id. Otherwise the id is a name-based UUID derived from the UID, and
  TodoTim keeps the original UID and path. TodoTim creates a new task with `PUT <home>/<calendar>/<uid>.ics`
  and `If-None-Match: *`, where UID = the task id.
- Objects are read from the **master** VTODO (the one without `RECURRENCE-ID`). An object without a UID,
  without a master (only overrides), or that cannot be parsed is skipped and never written. If a task's
  object becomes unreadable, TodoTim keeps the task as it was and does not take it for deleted. It writes
  nothing for that task until the object can be read again.

| TodoTim | iCalendar | Notes |
|---|---|---|
| content | `SUMMARY` | TEXT-escaped |
| description | `DESCRIPTION` | Removed when empty |
| priority p1 / p2 / p3 / p4 | `PRIORITY` 1 / 5 / 9 / 0 | Read: 1–4 → p1, 5 → p2, 6–9 → p3, 0 or absent → p4 |
| due date | `DUE;VALUE=DATE:yyyyMMdd` | TodoTim writes a DATE. A DATE-TIME from another client is read as its date in the local timezone (UTC and TZID converted, floating as written). When the date changes in TodoTim, or a repeat moves it, a DATE-TIME keeps its time of day and TZID and moves by the same number of days. `DTSTART`, if present, moves by the same number of days. A due date added to a task with a DATE-TIME `DTSTART` is written as the floating DATE-TIME `yyyyMMddT235959`, because DUE must have DTSTART's value type and be later than it. `DTSTART` moves back to that day if it was later. Setting a due date removes `DURATION`, because the two exclude each other. |
| completed | `STATUS:COMPLETED`, `COMPLETED:<UTC>`, `PERCENT-COMPLETE:100` | Reopen: `STATUS:NEEDS-ACTION`, and `COMPLETED` and `PERCENT-COMPLETE` are removed. Read: completed if `STATUS` is COMPLETED or CANCELLED, or if there is no STATUS but there is a COMPLETED. |
| parent (subtask) | `RELATED-TO;RELTYPE=PARENT:<parent UID>` | A `RELATED-TO` without `RELTYPE` also means parent. Other relation types are kept. |
| order | `X-APPLE-SORT-ORDER:<integer>` and `X-TODOTIM-ORDER:<double>` | Written together, with `X-APPLE-SORT-ORDER = floor(X-TODOTIM-ORDER)`. Read: `X-TODOTIM-ORDER` when `X-APPLE-SORT-ORDER` is absent or equals its floor; otherwise `X-APPLE-SORT-ORDER` (another client reordered the task and left our value stale); with neither, CREATED in seconds since 2001-01-01 (the epoch Apple-style sort orders use), so unordered tasks sort after ordered ones, oldest first. Ascending. |
| collapsed | `X-OC-HIDESUBTASKS:1` | The property Nextcloud Tasks uses; removed when expanded |
| section | `X-TODOTIM-SECTION;X-NAME=<name>;X-ORDER=<number>:<section id>` | Parameter values are quoted only when needed (when they contain `:`, `;` or `,`). A `"`, a newline or a `^` inside them is encoded as in [RFC 6868](https://www.rfc-editor.org/rfc/rfc6868) (`^'`, `^n`, `^^`). Readers accept quoted and unquoted values. Subtasks carry their root task's section line. Removed when the task has no section. |
| labels | `CATEGORIES` | See above |
| recurrence | `RRULE` | Read and kept as written; see below |
| createdAt | `CREATED` | Added when missing |
| updatedAt | `LAST-MODIFIED` (and `DTSTAMP`) | Set to the edit time on every write; used for last-writer-wins |

- **Other properties are preserved.** TodoTim keeps each task's original object and, on a change, rewrites
  only the properties in the table whose values differ. VALARM, DTSTART, GEO, URL, ATTACH, other clients'
  X- properties, parameters (as written, including quoted lists) and overrides (VTODOs with RECURRENCE-ID)
  survive unchanged.
- **Structure TodoTim cannot show is left alone.** TodoTim shows a subtask whose parent it cannot see
  (another list, an unreadable object) as a top-level task, and a task in an unknown section without one.
  It does not write that back: the server keeps `RELATED-TO`, `X-TODOTIM-SECTION` and the list until the
  task's parent, section or list is changed in TodoTim.
- **Repeating tasks.** If a task has an `RRULE`, completing it in TodoTim moves `DUE` (and `DTSTART`) to the
  next occurrence instead of completing it. This works for `FREQ=DAILY|WEEKLY|MONTHLY|YEARLY` with
  `INTERVAL`, `COUNT` and `UNTIL` (`WKST` is ignored). The next date counts from the current due date (today
  if there is none). Monthly and yearly steps keep the day of the month and skip months or years where that
  day doesn't exist: Jan 31 → Mar 31, and Feb 29 → the next leap year (RFC 5545). `COUNT` goes down by one,
  because the series now starts one occurrence later. A DATE `UNTIL` is compared with the date. A DATE-TIME
  `UNTIL` limits the occurrence's start time, which a date-only task doesn't know, so TodoTim advances only
  while the next date is at least two days before it. When the
  last occurrence (`COUNT=1`, or past `UNTIL`) is completed, or the rule has any other part (`BYDAY`,
  `BYMONTHDAY`, …), the task is completed normally.

## Sync protocol

1. **Listing**: one `PROPFIND` (Depth 1) on the calendar home, for `resourcetype`,
   `supported-calendar-component-set`, `sync-token`, `{http://calendarserver.org/ns/}getctag`,
   `owner-principal` and the properties above.
2. **Changes**: for each calendar whose `sync-token` differs from the one TodoTim stored, a
   `sync-collection` REPORT ([RFC 6578](https://www.rfc-editor.org/rfc/rfc6578)) since the stored token,
   asking for `getetag` and `calendar-data`. TodoTim follows truncated results (507) page by page, and a
   rejected token (403/409) falls back to a full listing. Objects reported without `calendar-data`
   (Xandikos leaves it out) are fetched with `calendar-multiget` (RFC 4791 §7.9), 100 at a time; an object
   the server then cannot return fails the sync instead of looking deleted. A calendar without a
   `sync-token` (RFC 6578 is optional) is compared by its `getctag`, and read whole with a `calendar-query`
   REPORT when that changes; so is a calendar whose server refuses sync-collection. An idle sync is the
   single PROPFIND.
3. **Merge**: three-way per entity: the local version, the server's, and the base (what the previous sync
   saw: the server objects and calendar properties, and each task as the local database held it; TodoTim
   keeps it in `caldav-state.json` next to `db.json`). A side that did not change since the
   base takes the other side's version. When both changed: tasks are last-writer-wins on
   `updatedAt`/`LAST-MODIFIED` (a delete wins a tie), and project, section and label fields take the
   local value. Merging never deletes a task or list on the server unless TodoTim deleted it locally
   (a tombstone). A list or task missing from the local database (for example after a reset) is
   downloaded again.
4. **Writes**, each conditional on the ETag it was based on: MKCALENDAR (+ PROPPATCH + share), PROPPATCH,
   `PUT` with `If-Match` (or `If-None-Match: *` for new tasks), **`MOVE`** with `If-Match` and `Overwrite: F`
   to move a task to another list, `DELETE` with `If-Match`, then calendar DELETEs. A 412 skips that write.
   Another pass then fetches the newer version and merges again (at most 3 passes). A local tombstone stays
   until the server delete succeeds. A list is deleted only after every task that moves out of it has moved.
   A sync with refused writes stays incomplete, and the next sync retries it. TodoTim writes up to 4 tasks at
   a time; a request answered 423 (Locked, which Xandikos sends while it stores another write) is sent again
   up to 4 times, with backoff.

## Servers

The mapping uses only standard CalDAV, plus properties that other servers store or refuse. TodoTim was
developed against Nextcloud; its live sync test (`LiveCalDAVTests`) also passes against Radicale 3.9 and
Xandikos 0.4.10. Servers that keep the calendar home on another host, such as iCloud, are refused (see
[Calendar home](#calendar-home)); Google Calendar's CalDAV has no VTODO.

## Limits (server data is untrusted)

The client accepts only https (http for localhost only), no requests, redirects or hrefs outside the allowed
root (see [Calendar home](#calendar-home)), and responses up to 32 MB (1 MB during discovery). One calendar
object may be at most 1 MB, 20,000 lines, 8 nesting levels and 1,000 components, and the parser refuses
anything malformed. XML with a DTD or entities is refused. Hrefs must be direct
children of the home or the calendar. Ids must be valid or are derived. Text is clipped (title 10,000
characters, description 100,000, names 1,000, 100 labels per task), subtasks nest at most 32 levels deep,
and the sections and labels properties may hold at most 5,000 entries and 1 MB.
