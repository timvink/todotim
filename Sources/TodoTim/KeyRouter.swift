import AppKit
import SwiftUI
import TodoCore

/// Handles Todoist's single-key shortcuts (q, a, j/k, 1–4, g i, …).
///
/// SwiftUI's `.onKeyPress` only fires for the focused view, and list rows are not
/// focusable, so a local NSEvent monitor is used instead. Keys pass through untouched
/// while a text field has focus, while a modifier (⌘/⌃/⌥) is held (menu commands
/// handle those), and in windows other than the main window and its task sheet.
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

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, let main = model.mainWindow else { return false }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        if model.isEditingText { return false }
        let chars = event.charactersIgnoringModifiers ?? ""

        // Task detail sheet: ↑/↓/j/k move between tasks.
        if window.sheetParent === main, model.detailTaskID != nil {
            switch (event.keyCode, chars) {
            case (Key.up, _), (_, "k"): model.moveDetail(-1); return true
            case (Key.down, _), (_, "j"): model.moveDetail(1); return true
            case (_, "e"): if let id = model.detailTaskID { model.toggleComplete(id) }; return true
            case (_, "1"), (_, "2"), (_, "3"), (_, "4"):
                model.setPriority(Priority(rawValue: Int(chars)!)!); return true
            default: return false
            }
        }
        guard window === main, window.attachedSheet == nil else { return false }

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
