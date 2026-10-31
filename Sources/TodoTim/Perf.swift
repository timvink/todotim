import AppKit
import Darwin
import TodoCore

/// Performance instrumentation, enabled with `TODOTIM_PERF=1`.
///
/// - Logs launch phases to stderr: process start → first frame of the main list (the Core
///   Animation commit of the run-loop turn in which the list appeared) and → interactive (the
///   end of the last main-thread turn of `longTurnMs` or more within `settleSeconds` after that
///   frame; the first frame when there is none).
/// - Measures main-thread busy time per run-loop turn (wake-up → next sleep), which covers
///   event handling, SwiftUI updates, layout and the Core Animation commit.
/// - With `TODOTIM_PERF_LAUNCH=1` (only with `TODOTIM_DATA_DIR` set) it prints one `LAUNCH`
///   summary line once the launch has settled and quits (see scripts/perf-launch.sh). The app
///   does not activate itself and sync stays off.
/// - With `TODOTIM_PERF_SCRIPT=1` (debug builds or `-DTODOTIM_PERF_SCRIPT`, and only with
///   `TODOTIM_DATA_DIR` set) it drives the app itself after launch (held j, typing in the
///   task sheet, opening the 1,000-task inbox, search) using events posted to its own queue
///   only, prints a summary and quits. Nothing is sent to other applications.
@MainActor
enum Perf {
    static let enabled = ProcessInfo.processInfo.environment["TODOTIM_PERF"] == "1"

    /// Launch timing only: logs the launch, then quits. Like the scripted run it needs a scratch
    /// database, keeps sync off and does not activate the app.
    static let launchOnly = enabled && usesScratchDataDir
        && ProcessInfo.processInfo.environment["TODOTIM_PERF_LAUNCH"] == "1"

    /// Modes that must not take focus from whatever the user is doing.
    static var runsInBackground: Bool { scripted || launchOnly }

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

    /// Process start (kernel start time) in seconds since 1970, read once.
    private static let processStart: Double = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        let start = info.kp_proc.p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }()

    /// Seconds since the process started (kernel start time), in wall-clock time.
    static func sinceProcessStart() -> Double {
        Date().timeIntervalSince1970 - processStart
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

    /// Times `body` and logs it when instrumentation is on. With `key`, the duration is also a
    /// field of the `LAUNCH` line.
    @discardableResult
    static func measure<T>(_ label: String, key: String? = nil, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = try body()
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        log(String(format: "%@: %.1f ms", label, ms))
        if let key { durations.append((key, ms)) }
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

    /// Named launch milestones in seconds since process start (also in the `LAUNCH` line).
    private static var marks: [(name: String, at: Double)] = []
    /// Named durations in milliseconds (`measure(_:key:_:)`), also in the `LAUNCH` line.
    private static var durations: [(name: String, ms: Double)] = []
    private static var listAppearedAt: Double?
    private static var firstFrameAt: Double?
    /// Main-thread turns after the first frame (start and end, seconds since process start).
    private static var turnsAfterFrame: [(start: Double, end: Double)] = []
    /// A main-thread turn at least this long after the first frame delays input noticeably.
    static let longTurnMs = 8.0
    /// How long the launch mode watches the main thread after the first frame.
    static let settleSeconds = 2.0

    /// Records a launch milestone and logs it.
    static func mark(_ name: String) {
        guard enabled else { return }
        let t = sinceProcessStart()
        marks.append((name, t))
        log(String(format: "mark %@: %.1f ms", name, t * 1000))
    }

    /// Called when the main list first appears. Core Animation commits its frame at the end of
    /// this run-loop turn; the `beforeWaiting` observer (ordered after Core Animation's) records
    /// that as the first frame.
    static func firstListAppeared() {
        guard enabled, listAppearedAt == nil else { return }
        listAppearedAt = sinceProcessStart()
    }

    /// Runs once, right after the first frame of the main list was committed.
    private static func firstFrameCommitted(at t: Double) {
        firstFrameAt = t
        log(String(format: "launch-to-first-frame (process start → first list frame committed): %.0f ms", t * 1000))
        if launchOnly {
            DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds) { MainActor.assumeIsolated { finishLaunchRun() } }
        }
        #if DEBUG || TODOTIM_PERF_SCRIPT
        if scripted { DispatchQueue.main.async { MainActor.assumeIsolated { PerfScript.start() } } }
        #endif
    }

    /// Logs the `LAUNCH` line (`key=value`, milliseconds; times since process start) and quits.
    private static func finishLaunchRun() {
        guard let frame = firstFrameAt else { return }
        let window = turnsAfterFrame.filter { $0.start < frame + settleSeconds }
        let long = window.filter { ($0.end - $0.start) * 1000 >= longTurnMs }
        let interactive = max(frame, long.last?.end ?? frame)
        let busy = window.reduce(0) { $0 + ($1.end - $1.start) } * 1000
        var fields = marks.map { String(format: "%@=%.1f", $0.name, $0.at * 1000) }
        fields += durations.map { String(format: "%@=%.2f", $0.name, $0.ms) }
        fields.append(String(format: "listAppeared=%.1f", (listAppearedAt ?? 0) * 1000))
        fields.append(String(format: "firstFrame=%.1f", frame * 1000))
        fields.append(String(format: "interactive=%.1f", interactive * 1000))
        fields.append(String(format: "busyAfterFrame=%.1f", busy))
        fields.append(String(format: "maxTurnAfterFrame=%.1f", window.map { ($0.end - $0.start) * 1000 }.max() ?? 0))
        fields.append("longTurnsAfterFrame=\(long.count)")
        log("LAUNCH " + fields.joined(separator: " "))
        for t in long {
            log(String(format: "long turn after first frame: %.1f–%.1f ms (%.1f ms)", t.start * 1000, t.end * 1000,
                       (t.end - t.start) * 1000))
        }
        NSApp.terminate(nil)
    }

    // MARK: - Main-thread busy time per run-loop turn

    private static var turnStart: CFAbsoluteTime?
    private static var turnStartCPU: Double = 0
    /// Wall-clock duration of each main-thread turn, in ms.
    private(set) static var turns: [Double] = []
    /// CPU time of the main thread in each turn, in ms (less than `turns` when the thread waited:
    /// blocked on I/O or IPC, or not scheduled on a busy machine).
    private(set) static var cpuTurns: [Double] = []
    private static var observers: [CFRunLoopObserver] = []

    /// User + system CPU time of the calling thread, in ms.
    static func threadCPUTime() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) * 1000 + Double(info.user_time.microseconds) / 1000
        let system = Double(info.system_time.seconds) * 1000 + Double(info.system_time.microseconds) / 1000
        return user + system
    }

    static func installRunLoopMonitor() {
        guard enabled, observers.isEmpty else { return }
        let rl = CFRunLoopGetMain()
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex(Int.min)) { _, _ in
            MainActor.assumeIsolated {
                turnStart = CFAbsoluteTimeGetCurrent()
                turnStartCPU = threadCPUTime()
            }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex(Int.max)) { _, _ in
            MainActor.assumeIsolated {
                let now = CFAbsoluteTimeGetCurrent()
                if let s = turnStart {
                    turns.append((now - s) * 1000)
                    cpuTurns.append(threadCPUTime() - turnStartCPU)
                    if launchOnly, firstFrameAt != nil {
                        let end = sinceProcessStart()
                        turnsAfterFrame.append((end - (now - s), end))
                    }
                }
                turnStart = nil
                if listAppearedAt != nil, firstFrameAt == nil { firstFrameCommitted(at: sinceProcessStart()) }
            }
        }
        for o in [wake, sleep] {
            CFRunLoopAddObserver(rl, o, .commonModes)
            observers.append(o!)
        }
    }

    static func resetTurns() {
        turns.removeAll(keepingCapacity: true)
        cpuTurns.removeAll(keepingCapacity: true)
    }

    static func summary(_ label: String, _ values: [Double]) -> String {
        guard !values.isEmpty else { return "\(label): no samples" }
        let s = values.sorted()
        func pct(_ p: Double) -> Double { s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
        let total = s.reduce(0, +)
        return String(format: "%@: n=%d total=%.0fms (cpu %.0fms) p50=%.1fms p95=%.1fms max=%.1fms >16ms=%d >50ms=%d",
                      label, s.count, total, cpuTurns.reduce(0, +), pct(0.5), pct(0.95), s.last!,
                      s.filter { $0 > 16.7 }.count, s.filter { $0 > 50 }.count)
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

    /// Runs `action` `times` times (after `prepare`, which is not measured), each followed by
    /// `settle` ms, and logs the median and maximum of the main-thread busy time per action
    /// (all run-loop turns until settled) and of its longest turn.
    private static func repeated(_ label: String, times: Int = 5, settle: Int = 500,
                                 prepare: () async -> Void = {}, _ action: () async -> Void) async {
        var busy: [Double] = []
        var cpu: [Double] = []
        var longest: [Double] = []
        for _ in 0..<times {
            await prepare()
            await pause(300)
            Perf.resetTurns()
            await action()
            await pause(settle)
            busy.append(Perf.turns.reduce(0, +))
            cpu.append(Perf.cpuTurns.reduce(0, +))
            longest.append(Perf.turns.max() ?? 0)
        }
        func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        Perf.log(String(format: "%@ ×%d: busy p50=%.1fms max=%.1fms (cpu p50=%.1fms), longest turn p50=%.1fms max=%.1fms",
                        label, times, median(busy), busy.max() ?? 0, median(cpu), median(longest), longest.max() ?? 0))
    }

    private static func key(_ chars: String, keyCode: UInt16, window: NSWindow, isARepeat: Bool = true) {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil,
                                       characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: isARepeat, keyCode: keyCode) else { return }
        NSApp.postEvent(e, atStart: false)
    }

    /// A single (non-repeat) key press.
    private static func press(_ chars: String, keyCode: UInt16, window: NSWindow) {
        key(chars, keyCode: keyCode, window: window, isARepeat: false)
    }

    /// Repetitions per phase (`TODOTIM_PERF_REPEAT`, default 1.0 = 150 key presses / 60 chars).
    private static let scale = Double(ProcessInfo.processInfo.environment["TODOTIM_PERF_REPEAT"] ?? "") ?? 1
    private static func n(_ base: Int) -> Int { max(1, Int((Double(base) * scale).rounded())) }

    /// Steps to run (`TODOTIM_PERF_ONLY`, comma-separated: open, held, sheet, search, switch,
    /// panel, quickadd, complete); all when unset. For profiling a single step.
    private static let only: Set<String>? = ProcessInfo.processInfo.environment["TODOTIM_PERF_ONLY"]
        .map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
    private static func step(_ name: String) -> Bool { only?.contains(name) ?? true }

    private static func run() async {
        guard let window = model.mainWindow else { Perf.log("no main window"); NSApp.terminate(nil); return }
        Perf.log("window occlusion visible: \(window.occlusionState.contains(.visible))")
        let store = model.store
        Perf.log("tasks in db: \(store.db.tasks.count), inbox open top-level: \(store.tasks(projectId: TodoStore.inboxID, sectionId: nil).count)")

        // 1. Switch away and back to the 1,000-task inbox.
        if step("open"), let firstProject = store.projects.first?.id {
            await phase("open project (≈80 tasks)") { model.sidebar = .project(firstProject) }
            await phase("open inbox (1,000 tasks)") { model.sidebar = .project(TodoStore.inboxID) }
        }

        // 2. Hold j: 150 auto-repeat key presses at 30 Hz, then k back up.
        if step("held") {
            await phase("held j ×\(n(150)) @30Hz (inbox)") {
                for _ in 0..<n(150) { key("j", keyCode: 38, window: window); await pause(33) }
            }
            await phase("held k ×\(n(150)) @30Hz (inbox)") {
                for _ in 0..<n(150) { key("k", keyCode: 40, window: window); await pause(33) }
            }
        }

        // 3. Typing in the task sheet title (insertText on the field editor, 12 chars/s).
        if step("sheet") {
            model.selectedTaskID = nil
            model.moveSelection(1)
            if let taskID = model.selectedTaskID {
                let originalTitle = store.task(taskID)?.content
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
                // Undo the typing so repeated runs see the same database.
                if let originalTitle { store.updateTask(taskID) { $0.content = originalTitle } }
            } else {
                Perf.log("no task selected")
            }
        }

        // 4. Search: type "review" one character at a time.
        if step("search") {
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
        }

        // 5. Switching projects (sidebar clicks set `sidebar` the same way).
        if step("switch") {
            let projectIDs = store.projects.prefix(10).map(\.id)
            var next = 0
            await repeated("switch project (≈100 tasks)", times: projectIDs.count, settle: 400) {
                model.sidebar = .project(projectIDs[next % projectIDs.count])
                next += 1
            }
            model.sidebar = .project(TodoStore.inboxID)
            await pause(600)
        }

        let inboxIDs = model.visibleTaskIDs()
        guard inboxIDs.count > 2 else {
            Perf.log("inbox too small for the remaining steps")
            NSApp.terminate(nil)
            return
        }

        // 6. Task panel: Return opens the selected task, Esc closes it.
        if step("panel") {
            var row = 0
            await repeated("open task panel (Return, inbox)", settle: 500, prepare: {
                model.detailTaskID = nil
                await pause(300)
                model.selectedTaskID = inboxIDs[(row * 7) % inboxIDs.count]
                row += 1
            }) {
                press("\r", keyCode: 36, window: window)
            }
            model.detailTaskID = nil
            await repeated("close task panel (Esc)", settle: 500, prepare: {
                model.openTask(inboxIDs[(row * 7) % inboxIDs.count])
                row += 1
                await pause(400)
            }) {
                press("\u{1b}", keyCode: 53, window: window)
            }
            model.detailTaskID = nil
            await pause(400)
        }

        // 7. Quick Add: q opens it (focused title), typing with Todoist syntax, Esc closes it.
        if step("quickadd") {
            model.selectedTaskID = nil
            await repeated("open Quick Add (q)", settle: 500, prepare: {
                model.showQuickAdd = false
                await pause(300)
            }) {
                press("q", keyCode: 12, window: window)
            }
            await pause(300)
            if let field = textInput(in: window.contentView, placeholder: "e.g. Buy milk tomorrow p1 @errands #Shopping"),
               !(window.firstResponder is NSTextView) {
                window.makeFirstResponder(field)
            }
            Perf.log("quick add first responder: \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
            let quickText = Array("Buy milk tomorrow p1 @errands #Project 2 ")
            await phase("typing \(quickText.count) chars in Quick Add @12/s", settle: 600) {
                for c in quickText {
                    (window.firstResponder as? NSTextView)?.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0))
                    await pause(83)
                }
            }
            await repeated("close Quick Add (Esc)", times: 1, settle: 500) {
                press("\u{1b}", keyCode: 53, window: window)
            }
            model.showQuickAdd = false
            await pause(400)
        }

        // 8. Completing a task with e (row leaves with an animation, toast), then undo.
        if step("complete") {
            let completeID = inboxIDs[2]
            await repeated("complete task (e, inbox)", settle: 700, prepare: {
                if let undo = model.toast?.undo { undo(); model.toast = nil }
                await pause(400)
                model.selectedTaskID = completeID
            }) {
                press("e", keyCode: 14, window: window)
            }
            await repeated("undo complete (toast)", settle: 700, prepare: {
                if model.toast == nil {
                    model.selectedTaskID = completeID
                    press("e", keyCode: 14, window: window)
                    await pause(800)
                }
            }) {
                model.toast?.undo?()
                model.toast = nil
            }
            if store.task(completeID)?.isCompleted == true { store.toggleComplete(completeID) }
            await pause(400)
        }
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
