# TodoTim for Omarchy (Linux)

The Linux app is a plugin for [Omarchy](https://omarchy.org) (4 and later), whose whole desktop (bar, menus,
notifications, lock screen) is one [Quickshell](https://quickshell.org) process with plugins. TodoTim
runs inside it, so it uses the shell's live theme, fonts and spacing, opens from a key binding like
Omarchy's own panels. It has no bar widget: `install.sh` enables it in `shell.json`'s `plugins` list,
not in `bar.layout`.

```
Omarchy shell (Quickshell, QML)                 todotim-engine (Swift, TodoCore)
┌───────────────────────────────┐   stdin       ┌──────────────────────────────────┐
│ Service.qml ── Process ───────┼──requests────▶│ Engine: TodoStore, persistence,  │
│   mirrors sidebar/rows/sync ◀─┼──events───────│ CalDAVSync / SyncController,     │
│ Panel.qml (FloatingWindow)    │   stdout      │ QuickAddParser, undo             │
│   app/AppView.qml …           │               └──────────────────────────────────┘
│                               │                 ~/.local/share/todotim/
└───────────────────────────────┘                   db.json, caldav-state.json,
                                                    settings.json, ui.json
```

- **The engine** (`Sources/TodoTimEngine`, executable `todotim-engine`) is the same TodoCore as the
  Mac app: the same `db.json` format, CalDAV sync, Quick Add parser and merge rules, so nothing about
  the data or the server contract is reimplemented. It is built as one fully static binary per
  architecture (x86_64, aarch64) with Swift's Static Linux SDK (`scripts/linux-build.sh`), so it needs
  no Swift runtime or shared libraries on the machine.
- **The plugin** (`linux/omarchy-plugin`) is QML only. It draws what the engine sends and turns keys
  and clicks into requests. It lives in `~/.config/omarchy/plugins/timvink.todotim/` with the engine
  in its `bin/`.

## Plugin

`manifest.json` declares three kinds:

- `service` (`Service.qml`): starts `todotim-engine` (the bundled `bin/todotim-engine`, else one on
  `PATH`, else `$TODOTIM_ENGINE`), restarts it with backoff when it exits, and mirrors its events into
  properties and a `ListModel` (`app/ModelSync.js` keeps delegates whose row key survives).
- `panel` (`Panel.qml`): a `FloatingWindow` titled "TodoTim" with `app/AppView.qml`. `keepLoaded`
  keeps it (and the selection) between summons. `omarchy-shell shell toggle timvink.todotim` shows or
  hides it; a payload `{"action":"quickAdd"}` opens Quick Add. Esc at the top of the list hides it.

Theme: `app/Theme.qml` binds to the shell's `Commons.Color` (foreground, background, accent, urgent,
muted, popup surfaces) and `Style` (monospace family, type scale, spacing, corner radius, motion), so
`omarchy-theme-set`, `omarchy font` and `[font] base-size` apply live. TodoTim has its own base text
size, `Theme.fontSize`, from which every font size, spacing and dialog width scales (the shell's
tokens times `fontSize / [font] base-size`, as the shell's `[spacing] scale-with-font` does): set in
Settings (`setAppearance`, saved in `ui.json`) or by `[omarchy] font_size` in `~/.todotim.toml`
(which wins and makes it read-only), else one pixel under the shell's base size (11 px by default),
which puts the body and meta text on the shell's own `body` and `caption` sizes. The named colors the shell does
not expose (green, yellow, orange, magenta, cyan, selection) come from the active theme's
`~/.local/state/omarchy/current/theme/colors.toml`, re-read whenever the shell's palette changes.
Priorities and due dates use them with Todoist's meanings (p1 red, p2 orange, p3 blue; overdue red,
today green, tomorrow orange, this week magenta). Project and label colors stay Todoist's palette.

Icons are Font Awesome code points (`app/Icons.js`) from the Nerd Font Omarchy uses as `monospace`.

## Engine protocol

JSON, one object per line. Requests carry a correlation number:

    {"req": 7, "cmd": "quickAdd", "text": "Renew passport friday p1 #Home", "projectId": "inbox"}

and get exactly one reply, `{"re": 7, "ok": true, "result": …}` or `{"re": 7, "ok": false, "error":
"…"}` (async commands such as `testConnection` and `syncNow` reply when they finish). Events have no
`re`:

- `{"event": "sidebar", "sidebar": {inbox, projects[], labels[]}}` with open-task counts.
- `{"event": "rows", "view": {…}, "rows": [...]}`: the current view flattened into rows of type `task`,
  `section`, `add` (the "Add task" row closing each area), `group` (project headers in label and search
  views), `empty` and `message`. Every row has a unique `key`.
- `{"event": "sync", "sync": {status, message, pending, lastSync, warning, credentialError, …}}`.
- `{"event": "fatal", "error": "…"}` when the engine cannot start (another engine holds the data folder).

The engine sends `sidebar` and `rows` only when they changed, and always before the reply to the
request that changed them, so an id in a reply (a new task to select) is already in the rows.

Commands: `hello`, `setView` (`view`: `{kind: "project", id}` / `{kind: "label", name}` /
`{kind: "search", query}`), `setShowCompleted`, `setSectionCollapsed`, `parseQuickAdd` (token
ranges are UTF-16 offsets, as QML strings index), `quickAdd`, `getTask`, `updateTask` (`content`,
`description`, `priority`, `due` or `dueText`, `labels`), `toggleComplete`, `completeTasks` (`ids`, one undo step), `deleteTask`, `undo` (hands back the
`selection` a completion or move request carried, so the client selects those tasks again),
`moveTask` (`projectId`, `sectionId`, `parentId`: a live, open task outside the moved one), `moveTargets`,
`moveTasks`, `indentTask`, `outdentTask`, `shiftTask`, `setTaskCollapsed`, `parseDate`, `addProject`,
`updateProject`, `deleteProject`, `moveProject`, `addSection`, `renameSection`, `deleteSection`,
`moveSection`, `addLabel`, `updateLabel`, `deleteLabel`, `syncNow`, `getSyncSettings`, `configureSync`,
`testConnection`, `getAppearance` and `setAppearance` (`fontSize`: pixels, or null for the default;
both reply `{fontSize, managed, minFontSize, maxFontSize}`, which `hello` also carries as `appearance`;
`managed` is the config path while `[omarchy] font_size` sets it, and `setAppearance` then fails). `Tests/TodoTimEngineTests` exercises them end to end.

The move dialog (`m`, `v`) uses two of them:

- `moveTargets` (`ids`, `query`) replies with TodoCore's ranked targets (`TodoStore.moveTargets`) for
  moving those tasks, as an array in display order of `{id, kind: "section" | "project" | "task", group:
  "currentProject" | "sections" | "projects" | "tasks", projectId, sectionId, parentId, title,
  projectName, projectColor (hex; null for the inbox), projectIsInbox, sectionName (a task's section),
  isCurrent, matches}`. `matches` are the query words' occurrences in `title` as merged `[start, end)`
  UTF-16 ranges, for highlighting. The dialog asks on every keystroke and applies only the reply to
  its latest request.
- `moveTasks` (`ids`, `target: {kind, projectId, sectionId, parentId}`, `selection`) looks the target
  up among those TodoCore offers for the tasks (so a parent is never one of them, below them, completed
  or deleted), moves them to its end (`TodoStore.moveTasks`; a sub-task whose parent moves too goes
  along) and pushes one undo step that puts every moved task and its sub-tasks back (project,
  section, parent and order) and re-collapses a parent the move opened. It replies with the moved
  `ids`, `projectId` and a `toast` ("Moved to Work / Meetings", "Made a sub-task of “Write report”",
  "3 tasks moved to Home"), or an error when the target is not valid for them.

One engine runs per data folder (`engine.lock`); a second one waits five seconds for the first to exit
(a restarting shell), then reports `fatal`. The engine writes the database and exits when stdin
closes or on SIGTERM/SIGINT/SIGHUP.

## Files and secrets

- Data: `$TODOTIM_DATA_DIR`, else `$XDG_DATA_HOME/todotim`, else `~/.local/share/todotim` (0700; files
  0600): `db.json` and `caldav-state.json` as on the Mac, `settings.json` (server URL, username,
  enabled), `ui.json` (collapsed sections, projects showing completed tasks, the text size chosen in Settings).
- The password is in the Secret Service keyring (GNOME Keyring on Omarchy) through `secret-tool`
  (attributes `application=todotim`, `account=user@host[:port]`), passed on stdin, never in argv or a
  file. `~/.todotim.toml` works as on the Mac, including `password_command` (run with `$SHELL -lc`).

## Development

Without an Omarchy machine:

    scripts/linux-test.sh                       # TodoCore + engine tests in Docker (swift:6.2.4)
    ARCHS=x86_64 scripts/linux-build.sh         # build/linux/x86_64/todotim-engine
    swift run todotim-engine --seed-demo --data-dir /tmp/tt   # the engine on macOS, by hand

`linux/dev/headless.sh` runs the plugin in a headless sway session (Docker image from
`linux/dev/Dockerfile`: Arch Linux with quickshell, sway, grim, wtype) with Omarchy's own
`shell/Commons` and `shell/Ui` from a checkout, a demo database, and a scenario of keys, theme
switches and screenshots (`linux/dev/scenario.sh`). `linux/dev/shell.qml` is the harness that loads
the plugin like the shell does.

On an Omarchy machine, symlink the plugin and point it at a local engine:

    ln -s "$PWD/linux/omarchy-plugin" ~/.config/omarchy/plugins/timvink.todotim
    mkdir -p linux/omarchy-plugin/bin && cp build/linux/x86_64/todotim-engine linux/omarchy-plugin/bin/
    omarchy-shell shell rescanPlugins && omarchy plugin enable timvink.todotim

The shell reloads the plugin when its files change (`linux/omarchy-plugin/bin/` is gitignored).

## Releases

`linux-vX.Y.Z` tags build `todotim-omarchy-X.Y.Z-x86_64.tar.gz` and `-aarch64.tar.gz` (see
CONTRIBUTING.md): the plugin with the version in its manifest, the static engine, `install.sh` and
`uninstall.sh`.
