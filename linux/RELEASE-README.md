# TodoTim for Omarchy

Keyboard-driven to-do lists for [Omarchy](https://omarchy.org) 4 and later, as a plugin of its Quickshell
desktop. Your tasks sync with your own CalDAV server, together with the TodoTim Mac and Android apps.

## Install or update

    ./install.sh

This copies the plugin to `~/.config/omarchy/plugins/timvink.todotim` and enables it, and adds a TodoTim entry to the app launcher (Super+Space). To open it with a key, bind one in
`~/.config/hypr/bindings.lua`:

    o.bind("SUPER + ALT + T", "TodoTim", { panel = "timvink.todotim" })
    o.bind("SUPER + ALT + Q", "TodoTim Quick Add", "omarchy-shell shell summon timvink.todotim '{\"action\":\"quickAdd\"}'")

Press `?` in TodoTim for the keyboard shortcuts, and `Ctrl+,` to set up sync or change the text size.

## Remove

    ./uninstall.sh            # keeps your tasks in ~/.local/share/todotim
    ./uninstall.sh --purge    # deletes them and the saved sync password too

More: https://github.com/timvink/todotim
