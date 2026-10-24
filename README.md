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
2. Verify that GitHub Actions built the zip from this repository (needs the [GitHub CLI](https://cli.github.com)):

       gh attestation verify TodoTim-vX.Y.Z.zip --repo timvink/todotim

   The `.sha256` file on the release only detects a damaged download (`shasum -a 256 -c TodoTim-vX.Y.Z.zip.sha256`);
   it comes from the same place as the zip, so it does not prove who built it.
3. Unzip it and move `TodoTim.app` to `/Applications`.
4. Open the app. macOS blocks it the first time. Go to **System Settings › Privacy & Security**, scroll to
   the message about TodoTim, click **Open Anyway**, and confirm.

TodoTim is ad-hoc signed with the hardened runtime, but not signed with an Apple Developer ID and not
notarized. macOS therefore cannot tell you who published it, and Apple has not scanned it. The attestation
check in step 2 is what ties the download to this repository. Don't remove the quarantine attribute with
`xattr`; use **Open Anyway** for this one app instead. (Developer ID signing plus notarization would remove this
step, but needs a paid Apple Developer account.)

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
in the macOS Keychain, per server: after you change the server URL, enter the password again. Local data lives in `~/Library/Application Support/TodoTim/db.json`.

### Configure with a dotfile

Instead of the Settings window, you can configure sync in `~/.todotim.toml` (or the path in `TODOTIM_CONFIG`),
which suits dotfile managers such as chezmoi. While the file has a `[sync]` table, the app uses it and shows
those settings read-only.

```toml
# TodoTim — https://github.com/timvink/todotim
repository = "https://github.com/timvink/todotim"

[sync]
enabled = true
server_url = "https://your.cloud/remote.php/dav/files/USERNAME/"
username = "USERNAME"
folder = "TodoTim"
# Optional. Prints the password; runs once when the Keychain has none, then the Keychain keeps it.
password_command = "rbw get 'Nextcloud app password'"
```

`password_command` runs in your login shell, so tools from Homebrew are found. Leave it out to enter the
password in Settings instead.

On the server, the folder holds an `index.json` with projects and labels, and one JSON file per project under
`projects/`. When two devices edit the same item, the most recent edit wins.

## Security

- **Credentials.** The app password is stored in the macOS Keychain (service `TodoTim WebDAV`), under an account
  named after both user and server, for example `tim@cloud.example.com`. A password saved for one server is never
  sent to another. TodoTim never logs it or shows `password_command` output.
- **HTTPS only.** TodoTim refuses `http://` server URLs (except `localhost`), and does not follow redirects
  that leave the configured server URL.
- **Config file trust.** `~/.todotim.toml` (and `TODOTIM_CONFIG`) can run a command and decides where the
  password is sent, so TodoTim only reads it when the file (after following symlinks) is a regular file owned by
  you and not writable by group or others, in a folder others can't write to. `chmod 600 ~/.todotim.toml` is
  a good default.
- **Remote data.** Data from the server is validated: ids must be short `[A-Za-z0-9_-]` strings, and
  responses, file counts, text lengths and subtask depth are limited.
- **Local data** in `~/Library/Application Support/TodoTim/` is readable only by you.

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

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
