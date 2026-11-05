# TodoTim for Omarchy (Linux)

The Linux app is a plugin for [Omarchy](https://omarchy.org) 4, whose whole desktop (bar, menus,
notifications, lock screen) is one [Quickshell](https://quickshell.org) process with plugins. TodoTim
runs inside it, so it uses the shell's live theme, fonts and spacing, opens from a key binding like
Omarchy's own panels, and adds a bar widget.

```
Omarchy shell (Quickshell, QML)                 todotim-engine (Swift, TodoCore)
┌───────────────────────────────┐   stdin       ┌──────────────────────────────────┐
│ Service.qml ── Process ───────┼──requests────▶│ Engine: TodoStore, persistence,  │
│   mirrors sidebar/rows/sync ◀─┼──events───────│ CalDAVSync / SyncController,     │
│ Panel.qml (FloatingWindow)    │   stdout      │ QuickAddParser, undo             │
│   app/AppView.qml …           │               └──────────────────────────────────┘
│ BarWidget.qml                 │                 ~/.local/share/todotim/
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
- `bar-widget` (`BarWidget.qml`): the Inbox count; click toggles the panel, right-click opens Quick Add.

Theme: `app/Theme.qml` binds to the shell's `Commons.Color` (foreground, background, accent, urgent,
muted, popup surfaces) and `Style` (monospace family, type scale, spacing, corner radius, motion), so
`omarchy-theme-set`, `omarchy font` and `[font] base-size` apply live. The named colors the shell does
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
`{kind: "search", query}`), `setShowCompleted`, `setSectionCollapsed`, `targets`, `parseQuickAdd` (token
ranges are UTF-16 offsets, as QML strings index), `quickAdd`, `getTask`, `updateTask` (`content`,
`description`, `priority`, `due` or `dueText`, `labels`), `toggleComplete`, `completeTasks` (`ids`, one undo step), `deleteTask`, `undo` (hands back the
`selection` a completion request carried, so the client selects those tasks again),
`moveTask`, `indentTask`, `outdentTask`, `shiftTask`, `setTaskCollapsed`, `parseDate`, `addProject`,
`updateProject`, `deleteProject`, `moveProject`, `addSection`, `renameSection`, `deleteSection`,
`moveSection`, `addLabel`, `updateLabel`, `deleteLabel`, `syncNow`, `getSyncSettings`, `configureSync`,
`testConnection`. `Tests/TodoTimEngineTests` exercises them end to end.

One engine runs per data folder (`engine.lock`); a second one waits five seconds for the first to exit
(a restarting shell), then reports `fatal`. The engine writes the database and exits when stdin
closes or on SIGTERM/SIGINT/SIGHUP.

## Files and secrets

- Data: `$TODOTIM_DATA_DIR`, else `$XDG_DATA_HOME/todotim`, else `~/.local/share/todotim` (0700; files
  0600): `db.json` and `caldav-state.json` as on the Mac, `settings.json` (server URL, username,
  enabled), `ui.json` (collapsed sections, projects showing completed tasks).
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
