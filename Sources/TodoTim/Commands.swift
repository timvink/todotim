import AppKit
import SwiftUI
import TodoCore

/// Menu bar commands. Single-key shortcuts (a, s, t, …) are listed here so they show in the
/// menu bar, but are executed by `KeyRouter` first; AppKit does not route plain letters to
/// menu key equivalents while a text field is focused, so typing is unaffected.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Quick Add Task") { model.showQuickAdd = true }
                .keyboardShortcut("q", modifiers: [])
            Button("New Task") { model.showQuickAdd = true }
                .keyboardShortcut("n")
            Button("Add Project…") { model.showAddProject = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Import from Todoist…") { model.showImportTodoist = true }
        }
        CommandGroup(after: .toolbar) {
            Button(model.currentProjectID.map { model.showsCompleted($0) } == true ? "Hide Completed Tasks" : "Show Completed Tasks") {
                if let pid = model.currentProjectID {
                    if model.showCompletedProjects.contains(pid) { model.showCompletedProjects.remove(pid) }
                    else { model.showCompletedProjects.insert(pid) }
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.currentProjectID == nil)
            Divider()
        }

        CommandMenu("Task") {
            Button("Add Task at Bottom") { model.addTaskInCurrentSection(atTop: false) }
                .keyboardShortcut("a", modifiers: [])
            Button("Add Task at Top") { model.addTaskInCurrentSection(atTop: true) }
                .keyboardShortcut("a", modifiers: .shift)
            Button("Add Section") { model.addSectionAtEnd() }
                .keyboardShortcut("s", modifiers: [])
                .disabled(model.currentProjectID == nil)
            Divider()
            Button("Open Task  ↩") { model.openSelected() }
                .disabled(!model.hasSelection)
            Button("Complete Task") { model.actionTaskID.map(model.toggleComplete) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.hasActionTask)
            Button("Indent") { model.indent() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.hasActionTask)
            Button("Outdent") { model.outdent() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.hasActionTask)
            Button("Move Up") {
                textOr(#selector(NSResponder.moveToBeginningOfDocument(_:))) { model.shift(-1) }
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!model.hasActionTask)
            Button("Move Down") {
                textOr(#selector(NSResponder.moveToEndOfDocument(_:))) { model.shift(1) }
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(!model.hasActionTask)
            Divider()
            Menu("Priority") {
                ForEach(Priority.allCases, id: \.self) { p in
                    Button(p.title) { model.setPriority(p) }
                        .keyboardShortcut(KeyEquivalent(Character(String(p.rawValue))), modifiers: [])
                }
            }
            .disabled(!model.hasActionTask)
            Button("Set Date…") { model.showPopover(.date) }
                .keyboardShortcut("t", modifiers: [])
                .disabled(!model.hasSelection)
            Button("Labels…") { model.showPopover(.labels) }
                .keyboardShortcut("l", modifiers: [])
                .disabled(!model.hasSelection)
            Button("Move to Project…") { model.showPopover(.move) }
                .keyboardShortcut("v", modifiers: [])
                .disabled(!model.hasSelection)
            Divider()
            Button("Delete Task…") {
                textOr(#selector(NSResponder.deleteToBeginningOfLine(_:))) { model.requestDelete() }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!model.hasActionTask)
        }

        CommandMenu("Navigate") {
            Button("Search") { model.focusSearch() }
                .keyboardShortcut("f")
            Button("Inbox") { model.goToInbox() }
                .keyboardShortcut("1")
            ForEach(Array(model.store.projects.prefix(8).enumerated()), id: \.element.id) { i, p in
                Button(p.name) { model.goToProject(number: i + 2) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 2))))
            }
            Divider()
            Button("Next Task") { model.moveSelection(1) }
                .keyboardShortcut("j", modifiers: [])
            Button("Previous Task") { model.moveSelection(-1) }
                .keyboardShortcut("k", modifiers: [])
            Divider()
            Button("Sync Now") { model.syncNow() }
                .keyboardShortcut("r")
        }

        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { model.showShortcuts = true }
                .keyboardShortcut("?", modifiers: [])
            Divider()
            Button("TodoTim on GitHub") {
                if let url = URL(string: model.repositoryURL), url.scheme?.lowercased() == "https" {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// ⌘⌫ / ⌘↑ / ⌘↓ mean something inside text fields; forward them there while editing.
    private func textOr(_ selector: Selector, _ action: () -> Void) {
        if model.isEditingText {
            NSApp.sendAction(selector, to: nil, from: nil)
        } else {
            action()
        }
    }
}

/// The list shown in the keyboard shortcuts sheet (`?`).
enum ShortcutCatalog {
    struct Item: Identifiable {
        let keys: String
        let action: String
        var id: String { keys + action }
    }

    static let groups: [(title: String, items: [Item])] = [
        ("General", [
            Item(keys: "Q  or  ⌘N", action: "Quick add task"),
            Item(keys: "/  or  ⌘F", action: "Search"),
            Item(keys: "?", action: "Show keyboard shortcuts"),
            Item(keys: "⌘R", action: "Sync now"),
            Item(keys: "⌘Z", action: "Undo complete / delete"),
            Item(keys: "⌘,", action: "Settings"),
        ]),
        ("Navigate", [
            Item(keys: "G  then  I", action: "Go to Inbox"),
            Item(keys: "G  then  S", action: "Go to Search"),
            Item(keys: "⌘1", action: "Go to Inbox"),
            Item(keys: "⌘2 … ⌘9", action: "Go to project 1 … 8"),
            Item(keys: "↓  or  J", action: "Select next task"),
            Item(keys: "↑  or  K", action: "Select previous task"),
            Item(keys: "G  then  G", action: "Select first task in section"),
            Item(keys: "⇧G", action: "Select last task in section"),
            Item(keys: "Esc", action: "Clear selection / close editor"),
        ]),
        ("Add", [
            Item(keys: "A", action: "Add task at bottom of section"),
            Item(keys: "⇧A", action: "Add task at top of section"),
            Item(keys: "S", action: "Add section"),
            Item(keys: "↩ (in editor)", action: "Add task, keep editor open"),
        ]),
        ("Selected task", [
            Item(keys: "↩", action: "Open task"),
            Item(keys: "E  or  ⌘↩", action: "Complete task"),
            Item(keys: "1  2  3  4", action: "Set priority"),
            Item(keys: "T", action: "Set date"),
            Item(keys: "L", action: "Labels"),
            Item(keys: "V", action: "Move to project"),
            Item(keys: "⌘]  /  ⌘[", action: "Indent / outdent"),
            Item(keys: "⌘↑  /  ⌘↓", action: "Move up / down"),
            Item(keys: "⌘⌫", action: "Delete task"),
        ]),
        ("Task view", [
            Item(keys: "↑ ↓  or  K J", action: "Previous / next task"),
            Item(keys: "T  /  L  /  V", action: "Date / labels / move"),
            Item(keys: "Esc  or  click outside", action: "Close"),
        ]),
    ]
}
