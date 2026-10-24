# TodoTim

A fast, native macOS to-do app modelled on [Todoist](https://todoist.com), that keeps your data in your own
[Nextcloud](https://nextcloud.com) (or any WebDAV) folder.

![TodoTim showing a project with sections, tasks and subtasks](docs/screenshot.png)

TodoTim keeps the parts of Todoist that matter for working through a list: projects, sections, tasks and
subtasks, all driven from the keyboard. It leaves out Today, Upcoming, the calendar and board views.

## Features

- Projects with colours, sections, tasks and nested subtasks
- Priorities (p1–p4), due dates, labels and descriptions
- Quick Add with natural language: `Renew passport next friday p1 @errands #Home /Admin`
- Keyboard shortcuts for almost everything (press `?` in the app)
- Search, label views, completed-task view, and undo for complete and delete
- Local-first: works offline, and syncs to a WebDAV folder in the background
- Native SwiftUI app with no third-party dependencies

## Install

1. Download `TodoTim-vX.Y.Z.zip` from the [latest release](https://github.com/timvink/todotim/releases/latest).
2. Unzip it and move `TodoTim.app` to `/Applications`.
3. The app is not notarized. Open it the first time by right-clicking it and choosing **Open**, or run:

       xattr -dr com.apple.quarantine /Applications/TodoTim.app

Requires macOS 15 (Sequoia) or later, on Apple silicon or Intel.

## Sync with Nextcloud

1. In Nextcloud, go to **Settings › Security › Devices & sessions** and create an app password.
2. In TodoTim, open **Settings** (`⌘,`) and fill in:
   - **Server URL**: `https://your.cloud/remote.php/dav/files/USERNAME/`
     (shown in Nextcloud Files under **Files settings › WebDAV**)
   - **Username** and the **app password**
   - **Folder**: where TodoTim keeps its files, `TodoTim` by default
3. Click **Test connection**, turn on sync, and close the window.

TodoTim syncs a few seconds after each change, every minute, and when you press `⌘R`. Your password is stored
in the macOS Keychain. Local data lives in `~/Library/Application Support/TodoTim/db.json`.

On the server, the folder holds an `index.json` with projects and labels, and one JSON file per project under
`projects/`. When two devices edit the same item, the most recent edit wins.

## Keyboard shortcuts

| Key | Action |
|---|---|
| `q`, `⌘N` | Quick Add |
| `a` / `⇧A` | Add task at the bottom / top of the current section |
| `s` | Add section |
| `↑` `↓`, `j` `k` | Move selection |
| `Enter` | Open selected task |
| `e`, `⌘↩` | Complete or reopen task |
| `1`–`4` | Set priority |
| `t` / `l` / `v` | Set date / labels / move to project |
| `⌘]` / `⌘[` | Indent / outdent (make subtask) |
| `⌘↑` / `⌘↓` | Move task up / down |
| `⌘⌫` | Delete task |
| `⌘Z` | Undo complete or delete |
| `/`, `⌘F` | Search |
| `g` then `i`, `⌘1` | Go to Inbox |
| `⌘2`…`⌘9` | Go to project 1–8 |
| `⇧⌘C` | Show or hide completed tasks |
| `⌘R` | Sync now |
| `?` | Show all shortcuts |

## Quick Add syntax

| Token | Meaning |
|---|---|
| `p1` … `p4` | Priority |
| `@label` | Label (created if new) |
| `#Project` | Project (multi-word names work) |
| `/Section` | Section in that project |
| `today`, `tomorrow`, `friday`, `next week`, `in 3 days`, `jan 5`, `2026-11-03`, `no date` | Due date |

## Build from source

    swift build
    swift test
    scripts/bundle.sh && open build/TodoTim.app

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and the release process, and [AGENTS.md](AGENTS.md) for the
architecture.

## License

[MIT](LICENSE)
