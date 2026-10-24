import AppKit
import Darwin
import TodoCore

/// Debug-only performance instrumentation, enabled with `TODOTIM_PERF=1`.
///
/// - Logs launch phases and launch-to-interactive time (process start → first frame of the
///   main list) to stderr.
/// - Measures main-thread busy time per run-loop turn (wake-up → next sleep), which covers
///   event handling, SwiftUI updates, layout and the Core Animation commit.
/// - With `TODOTIM_PERF_SCRIPT=1` (debug builds or `-DTODOTIM_PERF_SCRIPT`, and only with
///   `TODOTIM_DATA_DIR` set) it drives the app itself after launch (held j, typing in the
///   task sheet, opening the 1,000-task inbox, search) using events posted to its own queue
///   only, prints a summary and quits. Nothing is sent to other applications.
@MainActor
enum Perf {
    static let enabled = ProcessInfo.processInfo.environment["TODOTIM_PERF"] == "1"

    /// True when `TODOTIM_DATA_DIR` points at a separate database (test mode).
    static let usesScratchDataDir = !(ProcessInfo.processInfo.environment["TODOTIM_DATA_DIR"] ?? "").isEmpty

    /// The scripted run edits tasks, so it is compiled in only for debug builds or with
    /// `-DTODOTIM_PERF_SCRIPT` (see scripts/perf.sh), and only runs against `TODOTIM_DATA_DIR`.
    static let scripted: Bool = {
        #if DEBUG || TODOTIM_PERF_SCRIPT
        return enabled && usesScratchDataDir && ProcessInfo.processInfo.environment["TODOTIM_PERF_SCRIPT"] == "1"
        #else
        return false
        #endif
    }()

    /// Seconds since the process started (kernel start time), in wall-clock time.
    static func sinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_starttime
        let startSeconds = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - startSeconds
    }

    /// Optional copy of the log (`TODOTIM_PERF_LOG`), e.g. when stderr is not available under Instruments.
    private static let logFile: FileHandle? = ProcessInfo.processInfo.environment["TODOTIM_PERF_LOG"].flatMap { path in
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }

    static func log(_ message: String) {
        guard enabled else { return }
        let line = Data(String(format: "[perf] t=%.3fs %@\n", sinceProcessStart(), message).utf8)
        FileHandle.standardError.write(line)
        logFile?.write(line)
    }

    /// Times `body` and logs it when instrumentation is on.
    @discardableResult
    static func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = try body()
        log(String(format: "%@: %.1f ms", label, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        return r
    }

    /// Like `measure`, but only logs runs over 4 ms (for code that runs per view update).
    static func measureIfSlow<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = try body()
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if ms > 4 { log(String(format: "%@: %.1f ms", label, ms)) }
        return r
    }

    // MARK: - Launch

    private static var reportedFirstFrame = false

    /// Called when the main list first appears; logs after the frame is committed.
    static func firstListAppeared() {
        guard enabled, !reportedFirstFrame else { return }
        reportedFirstFrame = true
        DispatchQueue.main.async {
            log(String(format: "launch-to-interactive (process start → first list frame): %.0f ms", sinceProcessStart() * 1000))
            #if DEBUG || TODOTIM_PERF_SCRIPT
            if scripted { PerfScript.start() }
            #endif
        }
    }

    // MARK: - Main-thread busy time per run-loop turn

    private static var turnStart: CFAbsoluteTime?
    private(set) static var turns: [Double] = []
    private static var observers: [CFRunLoopObserver] = []

    static func installRunLoopMonitor() {
        guard enabled, observers.isEmpty else { return }
        let rl = CFRunLoopGetMain()
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex(Int.min)) { _, _ in
            MainActor.assumeIsolated { turnStart = CFAbsoluteTimeGetCurrent() }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex(Int.max)) { _, _ in
            MainActor.assumeIsolated {
                if let s = turnStart { turns.append((CFAbsoluteTimeGetCurrent() - s) * 1000) }
                turnStart = nil
            }
        }
        for o in [wake, sleep] {
            CFRunLoopAddObserver(rl, o, .commonModes)
            observers.append(o!)
        }
    }

    static func resetTurns() { turns.removeAll(keepingCapacity: true) }

    static func summary(_ label: String, _ values: [Double]) -> String {
        guard !values.isEmpty else { return "\(label): no samples" }
        let s = values.sorted()
        func pct(_ p: Double) -> Double { s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
        let total = s.reduce(0, +)
        return String(format: "%@: n=%d total=%.0fms p50=%.1fms p95=%.1fms max=%.1fms >16ms=%d >50ms=%d",
                      label, s.count, total, pct(0.5), pct(0.95), s.last!, s.filter { $0 > 16.7 }.count,
                      s.filter { $0 > 50 }.count)
    }
}

#if DEBUG || TODOTIM_PERF_SCRIPT
/// Scripted interaction for `TODOTIM_PERF_SCRIPT=1`. Runs inside the app only.
@MainActor
enum PerfScript {
    private static var model: AppModel { AppServices.shared.model }
    private static var activity: NSObjectProtocol?

    static func start() {
        // Keep timers precise while the window is in the background.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "TodoTim perf script")
        // `TODOTIM_PERF_DELAY` seconds: time to attach a profiler (`xctrace record --attach`).
        let delay = Double(ProcessInfo.processInfo.environment["TODOTIM_PERF_DELAY"] ?? "") ?? 0
        Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            await run()
        }
    }

    private static func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    /// Runs `body`, waits `settle` ms, and logs the run-loop turn statistics for the phase.
    private static func phase(_ label: String, settle: Int = 400, _ body: () async -> Void) async {
        await pause(300)
        Perf.log("begin \(label)")
        Perf.resetTurns()
        await body()
        await pause(settle)
        Perf.log(Perf.summary(label, Perf.turns))
    }

    private static func key(_ chars: String, keyCode: UInt16, window: NSWindow) {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil,
                                       characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: true, keyCode: keyCode) else { return }
        NSApp.postEvent(e, atStart: false)
    }

    /// Repetitions per phase (`TODOTIM_PERF_REPEAT`, default 1.0 = 150 key presses / 60 chars).
    private static let scale = Double(ProcessInfo.processInfo.environment["TODOTIM_PERF_REPEAT"] ?? "") ?? 1
    private static func n(_ base: Int) -> Int { max(1, Int((Double(base) * scale).rounded())) }

    private static func run() async {
        guard let window = model.mainWindow else { Perf.log("no main window"); return }
        Perf.log("window occlusion visible: \(window.occlusionState.contains(.visible))")
        let store = model.store
        Perf.log("tasks in db: \(store.db.tasks.count), inbox open top-level: \(store.tasks(projectId: TodoStore.inboxID, sectionId: nil).count)")

        // 1. Switch away and back to the 1,000-task inbox.
        let firstProject = store.projects.first!.id
        await phase("open project (≈80 tasks)") { model.sidebar = .project(firstProject) }
        await phase("open inbox (1,000 tasks)") { model.sidebar = .project(TodoStore.inboxID) }

        // 2. Hold j: 150 auto-repeat key presses at 30 Hz, then k back up.
        await phase("held j ×\(n(150)) @30Hz (inbox)") {
            for _ in 0..<n(150) { key("j", keyCode: 38, window: window); await pause(33) }
        }
        await phase("held k ×\(n(150)) @30Hz (inbox)") {
            for _ in 0..<n(150) { key("k", keyCode: 40, window: window); await pause(33) }
        }

        // 3. Typing in the task sheet title (insertText on the field editor, 12 chars/s).
        model.selectedTaskID = nil
        model.moveSelection(1)
        guard let taskID = model.selectedTaskID else { Perf.log("no task selected"); return }
        model.openTask(taskID)
        await pause(800)
        // The task view is a panel inside the main window; find its title field by placeholder.
        if let field = textInput(in: window.contentView, placeholder: "Task name") {
            if !window.makeFirstResponder(field) { (field as? NSTextField)?.selectText(nil) }
            await pause(200)
            Perf.log("sheet text input: \(type(of: field)), first responder: \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
            await phase("typing \(n(60)) chars in task sheet title @12/s", settle: 800) {
                for i in 0..<n(60) {
                    (window.firstResponder as? NSTextView)?.insertText(i % 6 == 5 ? " " : "x",
                                                                      replacementRange: NSRange(location: NSNotFound, length: 0))
                    await pause(83)
                }
            }
            window.makeFirstResponder(nil)
            await phase("task sheet j ×\(n(30)) @30Hz") {
                for _ in 0..<n(30) { key("j", keyCode: 38, window: window); await pause(33) }
            }
        } else {
            Perf.log("task sheet text field not found")
        }
        model.detailTaskID = nil
        await pause(600)

        // 4. Search: type "review" one character at a time.
        await phase("search typing 'review' @8/s") {
            model.sidebar = .search
            for c in "review" { model.searchQuery.append(c); await pause(120) }
        }
        window.makeFirstResponder(nil)  // leave the search field so j navigates
        await phase("held j ×\(n(60)) @30Hz (search results)") {
            for _ in 0..<n(60) { key("j", keyCode: 38, window: window); await pause(33) }
        }
        model.searchQuery = ""
        model.sidebar = .project(TodoStore.inboxID)
        await pause(500)
        Perf.log("script done")
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        NSApp.terminate(nil)
    }

    static func textInput(in view: NSView?, placeholder: String) -> NSView? {
        guard let view else { return nil }
        if let tf = view as? NSTextField, tf.isEditable,
           tf.placeholderString == placeholder || tf.placeholderAttributedString?.string == placeholder {
            return tf
        }
        for v in view.subviews { if let f = textInput(in: v, placeholder: placeholder) { return f } }
        return nil
    }
}
#endif
