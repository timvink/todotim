import AppKit
import SwiftUI
import TodoCore

/// Handles Todoist's single-key shortcuts (q, a, e, 1–4, …) and the vim motions (j/k, h/l or ←/→, Home/End,
/// gg/G, g i, Esc).
///
/// SwiftUI's `.onKeyPress` only fires for the focused view, and list rows are not
/// focusable, so a local NSEvent monitor is used instead. Keys pass through untouched
/// while a text field has focus, while a modifier (⌘/⌃/⌥) is held (menu commands
/// handle those), and in windows other than the main window (popovers, alerts, Settings).
/// While a picker popover is open, keys that reach the main window are forwarded to it. The move
/// dialog takes its keys first: ↑/↓ and ⌃J/⌃K (⌘J/⌘K) step its highlight, Esc closes it.
@MainActor
final class KeyRouter {
    private let model: AppModel
    private var monitor: Any?
    /// Time of the first key of a `g` chord.
    private var pendingG: Date?

    init(model: AppModel) { self.model = model }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    private enum Key {
        static let up: UInt16 = 126, down: UInt16 = 125, left: UInt16 = 123, right: UInt16 = 124,
                   home: UInt16 = 115, end: UInt16 = 119, pageUp: UInt16 = 116, pageDown: UInt16 = 121,
                   forwardDelete: UInt16 = 117, delete: UInt16 = 51, returnKey: UInt16 = 36, enter: UInt16 = 76, escape: UInt16 = 53
    }

    /// Plain keys that are also menu key equivalents. While a modal panel is open they are
    /// swallowed so they do not act on the list behind it.
    private static let menuKeys: Set<String> = ["q", "a", "A", "s", "t", "@", "v", "m", "j", "k", "h", "l", "e", "/", "?",
                                                "g", "G", "{", "}", "1", "2", "3", "4", "x", "J", "K", "u"]

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        // Only the main window; popovers, alerts and Settings handle their own keys.
        guard let window = event.window, let main = model.mainWindow, window === main,
              main.attachedSheet == nil else { return false }
        let chars = event.charactersIgnoringModifiers ?? ""
        // The move dialog is topmost (it can open over the task view), and its keys come before
        // ⌘J/⌘K, which would otherwise move the task behind it.
        if let move = model.moveDialog { return handleMoveDialog(event, chars: chars, move) }
        // ⌘J / ⌘K move the task like ⌘↓ / ⌘↑ (Ctrl+J / Ctrl+K in Omarchy).
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           chars == "j" || chars == "k" {
            guard model.popover == nil, !model.showShortcuts, !model.showQuickAdd, !model.isEditingText,
                  model.hasActionTask else { return false }
            model.shift(chars == "j" ? 1 : -1)
            return true
        }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        let isEscape = event.keyCode == Key.escape

        // A picker popover (t / @ / v) is open but the main window got the key: the popover is
        // not key. Hand the key to the popover's field, never to the list (`e` completes).
        if model.popover != nil {
            if isEscape { model.popover = nil; return true }
            if let popover = PopoverFocus.window {
                PopoverFocus.focusField(in: popover)
                popover.sendEvent(event)
            }
            return true
        }

        // In-window modals (topmost first).
        if model.showShortcuts {
            if isEscape || chars == "?" { model.showShortcuts = false }
            return isEscape || Self.menuKeys.contains(chars)
        }
        if model.showQuickAdd {
            if isEscape { model.showQuickAdd = false; return true }
            return !model.isEditingText && Self.menuKeys.contains(chars)
        }
        if model.detailTaskID != nil {
            // Esc while editing a field ends the edit (the field's onExitCommand); else closes.
            if model.isEditingText { return false }
            switch (event.keyCode, chars) {
            case (Key.escape, _): model.detailTaskID = nil
            case (Key.returnKey, _), (Key.enter, _): model.detailFocusRequest = .title
            case (_, "d"): model.detailFocusRequest = .details
            case (_, "a"): model.detailFocusRequest = .subtask
            case (Key.forwardDelete, _): model.requestDelete()
            case (Key.up, _), (_, "k"): model.moveDetail(-1)
            case (Key.down, _), (_, "j"): model.moveDetail(1)
            case (_, "e"), (_, "x"): if let id = model.detailTaskID { model.toggleComplete(id) }
            case (_, "1"), (_, "2"), (_, "3"), (_, "4"):
                model.setPriority(Priority(rawValue: Int(chars)!)!)
            case (_, "t"): model.popover = .date
            case (_, "@"): model.popover = .labels
            case (_, "m"), (_, "v"): model.showMoveDialog()
            case (_, "u"): return model.undoFromToast()
            default: return Self.menuKeys.contains(chars)
            }
            return true
        }
        if model.isEditingText { return false }

        if let g = pendingG {
            pendingG = nil
            if Date().timeIntervalSince(g) < 1.5 {
                switch chars {
                case "i": model.goToInbox(); return true
                case "s", "/": model.focusSearch(); return true
                case "g": model.moveSelectionToSectionEdge(last: false); return true
                default: break
                }
            }
        }

        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case Key.up: if shift { model.extendSelection(-1) } else { model.moveSelection(-1) }; return true
        case Key.down: if shift { model.extendSelection(1) } else { model.moveSelection(1) }; return true
        case Key.left: model.collapseSelected(); return true
        case Key.right: model.expandSelected(); return true
        case Key.returnKey, Key.enter:
            guard model.selectedTaskID != nil else { return false }
            model.openSelected(); return true
        case Key.escape:
            model.escape(); return true
        case Key.home: model.moveSelectionToSectionEdge(last: false); return true
        case Key.end: model.moveSelectionToSectionEdge(last: true); return true
        case Key.pageUp: model.pageList(-1); return true
        case Key.pageDown: model.pageList(1); return true
        case Key.forwardDelete:
            guard model.hasActionTask else { return false }
            model.requestDelete(); return true
        default: break
        }

        switch chars {
        case "j": model.moveSelection(1)
        case "k": model.moveSelection(-1)
        case "J": model.extendSelection(1)
        case "K": model.extendSelection(-1)
        case "h": model.collapseSelected()
        case "l": model.expandSelected()
        case "G": model.moveSelectionToSectionEdge(last: true)
        case "}": model.jumpSection(1)
        case "{": model.jumpSection(-1)
        case "q": model.showQuickAdd = true
        case "a": model.addTaskInCurrentSection(atTop: false)
        case "A": model.addTaskInCurrentSection(atTop: true)
        case "e", "x": model.completeSelection()
        case "1", "2", "3", "4":
            guard let id = model.selectedTaskID else { return false }
            model.setPriority(Priority(rawValue: Int(chars)!)!, for: id)
        case "t": model.showPopover(.date)
        case "@": model.showPopover(.labels)
        case "m", "v":
            guard model.hasActionTask else { return false }
            model.showMoveDialog()
        case "s": model.addSectionAtEnd()
        case "/": model.focusSearch()
        case "?": model.showShortcuts = true
        case "g": pendingG = Date()
        case "u": return model.undoFromToast()
        default: return false
        }
        return true
    }

    /// Keys while the move dialog is open. Typing goes to its field; Return is the field's submit.
    private func handleMoveDialog(_ event: NSEvent, chars: String, _ move: MoveDialogState) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case Key.escape: model.closeMoveDialog(); return true
        case Key.up where mods.isEmpty: move.step(-1); return true
        case Key.down where mods.isEmpty: move.step(1); return true
        default: break
        }
        if mods == .control || mods == .command {
            switch chars {
            case "j", "n": move.step(1); return true
            case "k", "p": move.step(-1); return true
            default: break
            }
        }
        // ⌘ shortcuts of the menus act on the task behind the dialog (⌘↩ completes, ⌘] indents,
        // ⌘⌫ deletes): only text editing and app-level ones pass; ⌘⌫ edits the field.
        if mods.contains(.command) {
            if event.keyCode == Key.delete {
                event.window?.firstResponder?.doCommand(by: #selector(NSResponder.deleteToBeginningOfLine(_:)))
                return true
            }
            return !["a", "c", "v", "x", "z", "q", "w", "h", ",", "`"].contains(chars.lowercased())
        }
        // Before the field has focus, nothing may reach the list behind the dialog.
        if !model.isEditingText {
            if event.keyCode == Key.returnKey || event.keyCode == Key.enter {
                model.performMove(move.highlighted)
            }
            return mods.intersection([.command, .control, .option]).isEmpty
        }
        return false
    }
}
