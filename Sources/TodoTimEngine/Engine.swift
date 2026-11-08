import Foundation
import Observation
import TodoCore

/// Where the engine keeps its files. Everything lives in one private folder:
/// `$TODOTIM_DATA_DIR`, else `$XDG_DATA_HOME/todotim`, else `~/.local/share/todotim`.
public struct EnginePaths: Sendable {
    public var dataDir: URL

    public init(dataDir: URL) { self.dataDir = dataDir }

    public var db: URL { dataDir.appendingPathComponent("db.json") }
    /// `CalDAVState`: where the calendars are and what the last sync saw.
    public var syncState: URL { dataDir.appendingPathComponent("caldav-state.json") }
    /// Sync settings entered in the app (server URL, username, enabled); the password is in the keyring.
    public var settings: URL { dataDir.appendingPathComponent("settings.json") }
    /// Per-device view state: collapsed sections, projects that show completed tasks, text size.
    public var ui: URL { dataDir.appendingPathComponent("ui.json") }
    public var lock: URL { dataDir.appendingPathComponent("engine.lock") }

    public static func resolve(explicit: String?, environment: [String: String]) -> EnginePaths {
        func expand(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true) }
        if let explicit, !explicit.isEmpty { return EnginePaths(dataDir: expand(explicit)) }
        if let dir = environment["TODOTIM_DATA_DIR"], !dir.isEmpty { return EnginePaths(dataDir: expand(dir)) }
        if let xdg = environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            return EnginePaths(dataDir: expand(xdg).appendingPathComponent("todotim", isDirectory: true))
        }
        let home = environment["HOME"].map(expand) ?? FileManager.default.homeDirectoryForCurrentUser
        return EnginePaths(dataDir: home.appendingPathComponent(".local/share/todotim", isDirectory: true))
    }
}

public struct EngineError: Error, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The TodoTim engine behind the Omarchy (Quickshell) UI: owns the `TodoStore`, persistence and
/// CalDAV sync, and talks JSON lines with the UI (see `docs/linux.md`).
///
/// Requests are `{"req": n, "cmd": "…", …arguments}`; each gets one reply `{"re": n, "ok": true,
/// "result": …}` or `{"re": n, "ok": false, "error": "…"}`. The engine pushes events
/// `{"event": "sidebar" | "rows" | "sync", …}` whenever what they describe changes, always before
/// the reply to the request that changed it, so a reply's ids are already in the rows.
@MainActor
public final class Engine {
    nonisolated public static let version = EngineVersion.current

    public let store: TodoStore
    public let sync: SyncController
    public let paths: EnginePaths
    let writer: PersistenceWriter?
    let output: (String) -> Void
    let calendar: Calendar
    let now: () -> Date
    var startupError: String?

    var view: ViewSpec = .project(TodoStore.inboxID)
    var showCompleted: Set<EntityID> = []
    var collapsedSections: Set<EntityID> = []
    /// The text size chosen in the app's Settings (ui.json); nil is the app's default.
    var fontSize: Int?
    /// `omarchy.font_size` from `~/.todotim.toml`, which wins over `fontSize` and makes it read-only.
    let configFontSize: Int?
    let configPath: String

    struct UndoEntry {
        var message: String
        var restore: () -> Void
        /// The client's selection when the change was made (opaque here), handed back by `undo`.
        var selection: JSON = .null
    }
    var undoStack: [UndoEntry] = []

    private var lastSidebar: String?
    private var lastRows: String?
    private var lastSyncEvent: String?
    private var lastDay: String = ""
    private var pushScheduled = false
    private var dayTimer: DispatchSourceTimer?

    /// - Parameters:
    ///   - config: `~/.todotim.toml` when it has settings (`[sync]` and `[omarchy] font_size` make
    ///     those settings read-only here).
    ///   - output: writes one protocol line (without the newline).
    public init(paths: EnginePaths, credentials: CredentialStore, config: AppConfig? = nil,
                configPath: String = AppConfig.defaultURL.path, configError: String? = nil, startSyncing: Bool = true,
                calendar: Calendar = .current, now: @escaping () -> Date = Date.init,
                output: @escaping (String) -> Void) {
        self.paths = paths
        self.output = output
        self.calendar = calendar
        self.now = now
        self.configFontSize = config?.omarchyFontSize
        self.configPath = configPath
        try? FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        chmod(paths.dataDir.path, 0o700)

        var startupError: String?
        var canSave = true
        let loaded: Database
        do {
            loaded = try LocalPersistence.loadChecked(from: paths.db)
        } catch let error as PersistenceError {
            loaded = Database()
            startupError = error.errorDescription
            // `.corrupt` moved the file aside, so saving is safe; `.unreadable` left it in place.
            if case .unreadable = error { canSave = false }
        } catch {
            loaded = Database()
            startupError = error.localizedDescription
            canSave = false
        }
        if let configError { startupError = [startupError, configError].compactMap { $0 }.joined(separator: "\n\n") }
        self.startupError = startupError
        store = TodoStore(db: loaded)
        writer = canSave ? PersistenceWriter(url: paths.db, delay: 0.3, onError: { error in
            FileHandle.standardError.write(Data("todotim-engine: failed to save database: \(error)\n".utf8))
        }) : nil

        var defaults: [String: Any] = [:]
        if let data = try? Data(contentsOf: paths.settings) { defaults[SyncController.settingsKey] = data }
        let engineDefaults = EngineDefaults(values: defaults)
        let settingsURL = paths.settings
        engineDefaults.onSet = { key, value in
            guard key == SyncController.settingsKey, let data = value as? Data else { return }
            try? LocalPersistence.writePrivately(data, to: settingsURL)
        }
        sync = SyncController(store: store, defaults: engineDefaults, credentials: credentials, config: config,
                              configPath: configPath, stateURL: paths.syncState, startSyncing: startSyncing)
        loadUIState()

        store.onLocalChange = { [weak self] in
            guard let self else { return }
            self.writer?.save(self.store.db)
            self.sync.scheduleSync()
            self.schedulePush()
        }
        sync.onDatabaseReplaced = { [weak self] in
            guard let self else { return }
            self.writer?.save(self.store.db)
            self.schedulePush()
        }
        sync.flushDatabase = { [weak self] in self?.writer?.flush() ?? false }
        lastDay = DueDate(now(), calendar: calendar).date
        observeSync()
    }

    /// Writes pending changes to disk (on quit).
    public func flush() {
        writer?.flush()
    }

    /// Re-renders date labels ("Today", "Tomorrow") after midnight; call about once a minute.
    public func tick() {
        let day = DueDate(now(), calendar: calendar).date
        guard day != lastDay else { return }
        lastDay = day
        lastRows = nil
        pushChanges()
    }

    public func startDayTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        timer.resume()
        dayTimer = timer
    }

    // MARK: - Protocol

    public func handle(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let request: JSON
        do {
            request = try JSON.parse(trimmed)
        } catch {
            send(["event": "error", "error": "Invalid request: not JSON"])
            return
        }
        let id = request["req"] ?? .null
        guard let cmd = request["cmd"]?.string else {
            reply(id, error: "Missing cmd")
            return
        }
        do {
            let result = try perform(cmd, request, id: id)
            pushChanges()
            if let result { reply(id, result: result) }
        } catch {
            pushChanges()
            reply(id, error: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    func send(_ message: JSON) {
        output(message.serialized())
    }

    func reply(_ id: JSON, result: JSON) {
        send(["re": id, "ok": true, "result": result])
    }

    func reply(_ id: JSON, error: String) {
        send(["re": id, "ok": false, "error": .string(error)])
    }

    // MARK: - Pushing state

    /// Pushes after the current main-queue turn (for changes that do not come from a request).
    func schedulePush() {
        guard !pushScheduled else { return }
        pushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pushScheduled = false
                self.pushChanges()
            }
        }
    }

    /// Sends the sidebar and the current view's rows when they differ from what was sent last.
    func pushChanges() {
        let sidebar = RowBuilder.sidebar(store).serialized()
        if sidebar != lastSidebar {
            lastSidebar = sidebar
            output("{\"event\":\"sidebar\",\"sidebar\":" + sidebar + "}")
        }
        if case .project(let pid) = view, store.project(pid) == nil { view = .project(TodoStore.inboxID) }
        var builder = RowBuilder(store: store, now: now(), calendar: calendar, showCompleted: showsCompleted,
                                 collapsedSections: collapsedSections)
        let rows = JSON.array(builder.build(view)).serialized()
        let viewJSON = viewDescription().serialized()
        let message = "{\"event\":\"rows\",\"view\":" + viewJSON + ",\"rows\":" + rows + "}"
        if message != lastRows {
            lastRows = message
            output(message)
        }
    }

    var showsCompleted: Bool {
        if case .project(let pid) = view { return showCompleted.contains(pid) }
        return false
    }

    func viewDescription() -> JSON {
        switch view {
        case .project(let pid):
            let p = store.project(pid) ?? store.inbox
            return ["kind": "project", "id": .string(p.id), "name": .string(p.name), "color": RowBuilder.projectColor(p),
                    "colorKey": .string(p.color), "isInbox": .bool(p.isInbox), "showCompleted": .bool(showsCompleted),
                    "count": .int(store.openTaskCount(projectId: p.id))]
        case .label(let name):
            let l = store.labels.first { $0.name == name }
            return ["kind": "label", "name": .string(name), "id": .string(l?.id),
                    "color": .string(l.map { ProjectColor.hex($0.color) }), "count": .int(store.openTaskCount(label: name))]
        case .search(let q):
            return ["kind": "search", "query": .string(q), "name": "Search"]
        }
    }

    // MARK: - Sync status

    /// Sends a `sync` event after any change of the controller's status (the change handler runs
    /// before the new value is set, so the event is built on the next main-queue turn).
    private func observeSync() {
        let ref = WeakEngine(self)
        withObservationTracking {
            _ = sync.status
            _ = sync.hasPendingChanges
            _ = sync.warning
            _ = sync.credentialError
            _ = sync.settings
            _ = sync.lastSync
        } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ref.engine?.pushSync()
                    ref.engine?.observeSync()
                }
            }
        }
    }

    func syncJSON() -> JSON {
        var status = "disabled"
        var message: String?
        switch sync.status {
        case .disabled: status = "disabled"
        case .idle: status = "idle"
        case .syncing: status = "syncing"
        case .error(let m): status = "error"; message = m
        }
        let lastSync = sync.lastSync.map { ISO8601DateFormatter().string(from: $0) }
        return [
            "status": .string(status), "message": .string(message), "lastSync": .string(lastSync),
            "pending": .bool(sync.hasPendingChanges), "warning": .string(sync.warning),
            "credentialError": .string(sync.credentialError),
            "enabled": .bool(sync.settings.enabled), "serverURL": .string(sync.settings.serverURL),
            "username": .string(sync.settings.username), "managed": .string(sync.managedConfigPath),
        ]
    }

    func pushSync() {
        let message = (["event": "sync", "sync": syncJSON()] as JSON).serialized()
        guard message != lastSyncEvent else { return }
        lastSyncEvent = message
        output(message)
    }

    // MARK: - Appearance

    /// `fontSize`: the base text size in pixels, or null for the app's default (which follows
    /// Omarchy's `[font] base-size`); `managed`: the config file that sets it, else null.
    func appearanceJSON() -> JSON {
        let sizes = AppConfig.omarchyFontSizes
        return ["fontSize": (configFontSize ?? fontSize).map(JSON.int) ?? .null,
                "managed": .string(configFontSize == nil ? nil : configPath),
                "minFontSize": .int(sizes.lowerBound), "maxFontSize": .int(sizes.upperBound)]
    }

    /// Saves the Settings' text size (`nil`: back to the default).
    func setFontSize(_ size: Int?) throws {
        guard configFontSize == nil else {
            throw EngineError("The text size comes from \(configPath) ([omarchy] font_size). Change it there.")
        }
        if let size, !AppConfig.omarchyFontSizes.contains(size) {
            throw EngineError("Text size must be from \(AppConfig.omarchyFontSizes.lowerBound) to \(AppConfig.omarchyFontSizes.upperBound) px")
        }
        fontSize = size
        saveUIState()
    }

    // MARK: - UI state (ui.json)

    private struct UIState: Codable {
        var collapsedSections: [String] = []
        var showCompleted: [String] = []
        /// Optional, so ui.json from before the setting still decodes.
        var fontSize: Int?
    }

    private func loadUIState() {
        guard let data = try? Data(contentsOf: paths.ui),
              let state = try? JSONDecoder().decode(UIState.self, from: data) else { return }
        collapsedSections = Set(state.collapsedSections)
        showCompleted = Set(state.showCompleted)
        fontSize = state.fontSize.flatMap { AppConfig.omarchyFontSizes.contains($0) ? $0 : nil }
    }

    func saveUIState() {
        let state = UIState(collapsedSections: collapsedSections.sorted(), showCompleted: showCompleted.sorted(),
                            fontSize: fontSize)
        if let data = try? JSONEncoder().encode(state) { try? LocalPersistence.writePrivately(data, to: paths.ui) }
    }
}

/// A weak reference that can cross into `@Sendable` closures; only dereferenced on the main actor.
private final class WeakEngine: @unchecked Sendable {
    weak var engine: Engine?
    init(_ engine: Engine) { self.engine = engine }
}
