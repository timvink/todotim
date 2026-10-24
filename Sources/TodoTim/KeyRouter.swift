import AppKit
import SwiftUI
import TodoCore

/// Handles Todoist's single-key shortcuts (q, a, j/k, 1–4, g i, …).
///
/// SwiftUI's `.onKeyPress` only fires for the focused view, and list rows are not
/// focusable, so a local NSEvent monitor is used instead. Keys pass through untouched
/// while a text field has focus, while a modifier (⌘/⌃/⌥) is held (menu commands
/// handle those), and in windows other than the main window (popovers, alerts, Settings).
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
        static let up: UInt16 = 126, down: UInt16 = 125, returnKey: UInt16 = 36, enter: UInt16 = 76, escape: UInt16 = 53
    }

    /// Plain keys that are also menu key equivalents. While a modal panel is open they are
    /// swallowed so they do not act on the list behind it.
    private static let menuKeys: Set<String> = ["q", "a", "A", "s", "t", "l", "v", "j", "k", "e", "/", "?", "g",
                                                "1", "2", "3", "4"]

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        // Only the main window; popovers, alerts and Settings handle their own keys.
        guard let window = event.window, let main = model.mainWindow, window === main,
              main.attachedSheet == nil else { return false }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        let chars = event.charactersIgnoringModifiers ?? ""
        let isEscape = event.keyCode == Key.escape

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
            case (Key.up, _), (_, "k"): model.moveDetail(-1)
            case (Key.down, _), (_, "j"): model.moveDetail(1)
            case (_, "e"): if let id = model.detailTaskID { model.toggleComplete(id) }
            case (_, "1"), (_, "2"), (_, "3"), (_, "4"):
                model.setPriority(Priority(rawValue: Int(chars)!)!)
            case (_, "t"): model.popover = .date
            case (_, "l"): model.popover = .labels
            case (_, "v"): model.popover = .move
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
                default: break
                }
            }
        }

        switch event.keyCode {
        case Key.up: model.moveSelection(-1); return true
        case Key.down: model.moveSelection(1); return true
        case Key.returnKey, Key.enter:
            guard model.selectedTaskID != nil else { return false }
            model.openSelected(); return true
        case Key.escape:
            model.clearSelection(); return true
        default: break
        }

        switch chars {
        case "j": model.moveSelection(1)
        case "k": model.moveSelection(-1)
        case "q": model.showQuickAdd = true
        case "a": model.addTaskInCurrentSection(atTop: false)
        case "A": model.addTaskInCurrentSection(atTop: true)
        case "e": if let id = model.selectedTaskID { model.toggleComplete(id) }
        case "1", "2", "3", "4":
            guard let id = model.selectedTaskID else { return false }
            model.setPriority(Priority(rawValue: Int(chars)!)!, for: id)
        case "t": model.showPopover(.date)
        case "l": model.showPopover(.labels)
        case "v": model.showPopover(.move)
        case "s": model.addSectionAtEnd()
        case "/": model.focusSearch()
        case "?": model.showShortcuts = true
        case "g": pendingG = Date()
        default: return false
        }
        return true
    }
}
