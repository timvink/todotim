#if DEBUG
import AppKit
import SwiftUI
import TodoCore

/// Debug-only test hook: with `TODOTIM_UI_TEST=1` and `TODOTIM_DATA_DIR` set, reads commands
/// from stdin (one per line) and drives the app in-process, for screenshots and drag tests.
/// The app does not activate itself in this mode.
///
///     project N            go to project N (1 = Inbox)
///     select I             select visible task I (0-based)
///     detail [I]           open the task view (for visible task I, default the selection)
///     close                close every modal
///     quickadd TEXT        open Quick Add (TEXT is typed into it when given)
///     shortcuts            open the shortcuts list
///     popover date|labels|move
///     drag I [panel]       start dragging visible task I (in the task panel's sub-task list)
///     target before|after|child I    set the drop target to visible task I
///     target start|end S   section S (index; -1 = no section)
///     drop                 perform the drop
///     enddrag              cancel the drag
///     collapse S           toggle section S
///     order                print the visible task titles with depths
///     key esc|up|down|return|j|k|h|l|g|G|a|e|t|v|@|/|u   post a key press to the app's own queue
///     search TEXT          open search with this query
///     state                print the list, the selection and which modals are open
///     addtask TEXT         add a task with this raw title to the current project
///     hittest X Y          print the views a click at window point (X, Y) from the top left would reach
///     appearance light|dark|system   switch the app's appearance (for screenshots)
///     sidebar show|hide    show or hide the sidebar
///     snapshot PATH [popover]   render the window (or the open popover) into a PNG at PATH (works on
///                          any Space, no capture permission)
///     mousedrag X1 Y1 X2 Y2   a real mouse drag between window points (moves the system cursor)
///     quit
@MainActor
enum UITestHook {
    static let active: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["TODOTIM_UI_TEST"] == "1" && !(env["TODOTIM_DATA_DIR"] ?? "").isEmpty
    }()

    static func start() {
        guard active else { return }
        Thread.detachNewThread {
            while let line = readLine() {
                let cmd = line
                DispatchQueue.main.async { MainActor.assumeIsolated { run(cmd) } }
            }
        }
    }

    private static var model: AppModel { AppServices.shared.model }
    private static var store: TodoStore { model.store }

    private static func out(_ s: String) {
        FileHandle.standardError.write(Data("[ui] \(s)\n".utf8))
    }

    private static func visible(_ i: Int) -> EntityID? {
        let ids = model.visibleTaskIDs()
        return ids.indices.contains(i) ? ids[i] : nil
    }

    private static func section(_ i: Int) -> EntityID? {
        guard i >= 0, let pid = model.currentProjectID else { return nil }
        let s = store.sections(in: pid)
        return s.indices.contains(i) ? s[i].id : nil
    }

    static func run(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard let cmd = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        let arg2 = parts.count > 2 ? parts[2] : ""
        switch cmd {
        case "project": model.goToProject(number: Int(arg) ?? 1)
        case "select": model.selectedTaskID = visible(Int(arg) ?? 0)
        case "detail":
            if let i = Int(arg), let id = visible(i) { model.openTask(id) } else { model.openSelected() }
        case "close":
            model.detailTaskID = nil; model.showQuickAdd = false; model.showShortcuts = false; model.popover = nil
        case "quickadd":
            model.showQuickAdd = true
            let text = parts.dropFirst().joined(separator: " ")
            if !text.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    (model.mainWindow?.firstResponder as? NSTextView)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                }
            }
        case "shortcuts": model.showShortcuts = true
        case "popover":
            model.popover = ["date": .date, "labels": .labels, "move": .move][arg]
        case "drag":
            if let id = visible(Int(arg) ?? 0) { model.beginDrag(id, rowHeight: 50, inPanel: arg2 == "panel", trackMouse: false) }
        case "target":
            let n = Int(arg2) ?? 0
            switch arg {
            case "before": model.drag.setTarget(visible(n).map(DropTarget.before))
            case "after": model.drag.setTarget(visible(n).map(DropTarget.after))
            case "child": model.drag.setTarget(visible(n).map(DropTarget.firstChild))
            case "start", "end":
                guard let pid = model.currentProjectID else { break }
                let sid = section(n)
                model.drag.setTarget(arg == "start" ? .sectionStart(projectId: pid, sectionId: sid)
                                                    : .sectionEnd(projectId: pid, sectionId: sid))
            default: break
            }
        case "drop": out("drop -> \(model.performDrop())")
        case "enddrag": model.drag.end()
        case "collapse":
            if let sid = section(Int(arg) ?? 0) {
                if model.collapsedSections.contains(sid) { model.collapsedSections.remove(sid) } else { model.collapsedSections.insert(sid) }
            }
        case "order":
            for item in model.cachedDisplay().items {
                switch item {
                case .task(let r): out(String(repeating: "  ", count: r.depth + 1) + (store.task(r.id)?.content ?? "?"))
                case .sectionHeader(let s, _, let c): out("## \(s.name)\(c ? " (collapsed)" : "")")
                default: break
                }
            }
            out("end")
        case "key":
            // key esc|up|down|<char>: a key press posted to this app's own queue.
            let codes: [String: (String, UInt16)] = ["esc": ("\u{1b}", 53), "up": ("\u{F700}", 126), "down": ("\u{F701}", 125),
                                                    "return": ("\r", 36), "j": ("j", 38), "k": ("k", 40), "h": ("h", 4),
                                                    "l": ("l", 37), "g": ("g", 5), "G": ("G", 5), "a": ("a", 0), "e": ("e", 14),
                                                    "t": ("t", 17), "v": ("v", 9), "@": ("@", 19), "/": ("/", 44), "u": ("u", 32)]
            guard let w = model.mainWindow, let (chars, code) = codes[arg] else { break }
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                NSApp.postEvent(e, atStart: false)
            }
        case "search":
            model.focusSearch()
            model.searchQuery = parts.dropFirst().joined(separator: " ")
        case "state":
            let view = model.sidebar.map { String(describing: $0) } ?? "nil"
            let onScreen = model.selectedTaskID.map { model.visibleRows?.ids.contains($0) == true }
            out("view=\(view) selected=\(model.selectedTaskID.flatMap { store.task($0)?.content } ?? "nil")"
                + (onScreen.map { " onScreen=\($0)" } ?? "") + " editingText=\(model.isEditingText)")
            out("detail=\(model.detailTaskID.flatMap { store.task($0)?.content } ?? "nil") quickAdd=\(model.showQuickAdd) shortcuts=\(model.showShortcuts) editor=\(model.editor != nil) collapsed=\(model.collapsedSections.count)")
        case "addtask":
            // addtask TEXT: adds a raw (unparsed) task to the current project.
            store.addTask(content: parts.dropFirst().joined(separator: " "), projectId: model.currentProjectID ?? TodoStore.inboxID)
        case "appearance":
            NSApp.appearance = ["light": NSAppearance(named: .aqua), "dark": NSAppearance(named: .darkAqua)][arg] ?? nil
        case "snapshot":
            // snapshot PATH [popover]: the main window, or the open popover (a window of its own).
            let window = arg2 == "popover"
                ? NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
                : model.mainWindow
            guard let w = window, let view = w.contentView?.superview ?? w.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { break }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
        case "sidebar":
            model.columnVisibility = arg == "hide" ? .detailOnly : .all
        case "hittest":
            guard let w = model.mainWindow, let frame = w.contentView?.superview,
                  let x = Double(arg), let y = Double(arg2) else { break }
            let p = NSPoint(x: x, y: w.frame.height - y)
            var chain: [String] = []
            var v = frame.hitTest(frame.convert(p, from: nil))
            while let view = v, chain.count < 6 { chain.append(String(describing: type(of: view))); v = view.superview }
            out("hittest \(x),\(y): " + chain.joined(separator: " < "))
        case "mousedrag":
            // mousedrag X1 Y1 X2 Y2: a real mouse drag (window points from the top left), posted to
            // the system (it moves the real cursor; needs Accessibility). Exercises the SwiftUI drop delegates.
            let n = line.split(separator: " ").dropFirst().compactMap { Double($0) }
            guard n.count == 4, let w = model.mainWindow, let screen = w.screen ?? NSScreen.screens.first else { break }
            func global(_ x: Double, _ y: Double) -> CGPoint {
                // CG global coordinates: origin at the top left of the main screen.
                let p = NSPoint(x: w.frame.minX + x, y: w.frame.maxY - y)
                return CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY) - p.y)
            }
            out("mousedrag window=\(w.frame) from=\(global(n[0], n[1])) to=\(global(n[2], n[3]))")
            // Above other apps' windows: an app started from a shell is not allowed to activate itself.
            w.level = .floating
            w.orderFrontRegardless()
            mouseDrag(from: global(n[0], n[1]), to: global(n[2], n[3]))
            return
        case "quit": NSApp.terminate(nil)
        default: out("unknown command \(cmd)")
        }
        out("ok \(line)")
    }

    /// Posts mouse down, a slow drag and mouse up to this process from a background thread, so
    /// the main thread is free to run AppKit's drag session while the events arrive.
    private static func mouseDrag(from a: CGPoint, to b: CGPoint) {
        Thread.detachNewThread {
            func post(_ type: CGEventType, _ p: CGPoint) {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            post(.leftMouseDown, a)
            usleep(150_000)
            let steps = 40
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                usleep(25_000)
            }
            usleep(400_000)
            post(.leftMouseUp, b)
            usleep(1_200_000)
            DispatchQueue.main.async { MainActor.assumeIsolated { out("ok mousedrag") } }
        }
    }
}
#endif
