import AppKit
import SwiftUI
import TodoCore

/// Owns the store, sync controller and persistence. Created once at launch.
///
/// Environment variables (for development and screenshots):
/// - `TODOTIM_DATA_DIR`: directory holding `db.json` instead of Application Support. Sync
///   settings then come from a separate UserDefaults suite (`nl.timvink.todotim.dev`), so
///   test data never syncs to the server configured for the real database.
/// - `TODOTIM_SEED=1`: inserts sample data when the database has no tasks; `TODOTIM_SEED=large`
///   inserts the 5,000-task performance fixture instead. Only with `TODOTIM_DATA_DIR`; sync is
///   then off and no config file is read.
/// - `TODOTIM_CONFIG`: config file instead of `~/.todotim.toml` (see `AppConfig`). With
///   `TODOTIM_DATA_DIR` set, a config file is only read when this is set too.
/// - `TODOTIM_PERF=1` / `TODOTIM_PERF_SCRIPT=1`: timing logs and a scripted run (see `Perf`).
@MainActor
final class AppServices {
    static let shared = AppServices()

    let store: TodoStore
    let sync: SyncController
    let model: AppModel
    let dbURL: URL
    let keyRouter: KeyRouter
    /// Writes snapshots off the main thread. nil when the existing database file could not be
    /// read: it must never be overwritten with the empty database the app started with.
    private let writer: PersistenceWriter?

    private init() {
        let env = ProcessInfo.processInfo.environment
        let customDir = env["TODOTIM_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        if let customDir {
            dbURL = URL(fileURLWithPath: (customDir as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("db.json")
        } else {
            dbURL = LocalPersistence.fileURL
        }
        Perf.installRunLoopMonitor()
        Perf.mark("servicesStart")
        // When the first main-actor job queued at launch runs (the sync loop starts like this).
        if Perf.enabled { Task { @MainActor in Perf.mark("firstMainTask") } }
        let url = dbURL
        var startupError: String?
        var canSave = true
        let loaded: Database
        do {
            loaded = try Perf.measure("load db.json", key: "loadDB") { try LocalPersistence.loadChecked(from: url) }
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
        store = Perf.measure("build store", key: "buildStore") { TodoStore(db: loaded) }
        writer = canSave ? PersistenceWriter(url: url, delay: 0.3, onError: { error in
            NSLog("TodoTim: failed to save database: \(error)")
        }) : nil
        // Seeding and the perf modes only touch a scratch database (`TODOTIM_DATA_DIR`), with sync off.
        let seed = customDir == nil ? nil : env["TODOTIM_SEED"].flatMap { $0 == "1" || $0 == "large" ? $0 : nil }
        let scratchMode = customDir != nil && (seed != nil || Perf.runsInBackground)
        if let seed, canSave, store.db.tasks.isEmpty {
            if seed == "large" { SampleData.seedLarge(store) } else { SampleData.seed(store) }
            writer?.save(store.db)
            writer?.flush()
        }
        let defaults: UserDefaults
        if scratchMode {
            // Empty settings suite, cleared every launch: sync stays disabled.
            let suite = "nl.timvink.todotim.scratch"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            defaults = UserDefaults(suiteName: suite) ?? .standard
        } else {
            defaults = customDir == nil ? UserDefaults.standard : (UserDefaults(suiteName: "nl.timvink.todotim.dev") ?? .standard)
        }
        // In test mode (`TODOTIM_DATA_DIR`) the real ~/.todotim.toml is ignored so seed data never
        // syncs to the real server; an explicit `TODOTIM_CONFIG` is still honoured, except when
        // seeding or running the perf script.
        var config: AppConfig?
        let configURL = AppConfig.defaultURL
        if !scratchMode, customDir == nil || !(env["TODOTIM_CONFIG"] ?? "").isEmpty {
            do {
                config = try AppConfig.load(from: configURL)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                startupError = [startupError, message].compactMap { $0 }.joined(separator: "\n\n")
            }
        }
        if let ignored = config?.ignoredKeys, !ignored.isEmpty {
            NSLog("TodoTim: \(configURL.path): ignoring \(ignored.joined(separator: ", ")) (no longer used; sync uses CalDAV)")
        }
        // The CalDAV sync state sits next to the database it describes. Syncing starts after the
        // first frame (`AppDelegate.startSyncAfterFirstFrame`): the first sync reads the Keychain
        // and the state file, which must not delay the window.
        sync = SyncController(store: store, defaults: defaults, credentials: KeychainCredentialStore(),
                              config: config, configPath: configURL.path,
                              stateURL: url.deletingLastPathComponent().appendingPathComponent("caldav-state.json"),
                              startSyncing: false)
        model = AppModel(store: store, sync: sync, defaults: defaults)
        model.startupError = startupError
        // Only https links are opened from the Help menu.
        model.repositoryURL = config.map(\.repository).flatMap { URL(string: $0) }
            .flatMap { $0.scheme?.lowercased() == "https" && $0.host != nil ? $0.absoluteString : nil }
            ?? AppConfig.defaultRepository
        keyRouter = KeyRouter(model: model)

        store.onLocalChange = { [weak self] in
            guard let self else { return }
            self.writer?.save(self.store.db)
            self.sync.scheduleSync()
        }
        // A sync merge replaces the database without calling `onLocalChange`; persist it too.
        sync.onDatabaseReplaced = { [weak self] in
            guard let self else { return }
            self.writer?.save(self.store.db)
        }
        // Without a writer (unreadable database file) the state is never saved either.
        sync.flushDatabase = { [weak self] in self?.writer?.flush() ?? false }
        Perf.mark("servicesDone")
    }

    /// Commits pending edits and writes the database synchronously (on quit).
    func flush() {
        model.flushDetailEdits()
        writer?.flush()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Perf.mark("willFinishLaunching") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Perf.mark("didFinishLaunching")
            NSApp.setActivationPolicy(.regular)
            // A perf run (or the debug UI test hook) must not take focus from whatever the user
            // is doing.
            var quiet = Perf.runsInBackground
            #if DEBUG
            quiet = quiet || UITestHook.active
            UITestHook.start()
            #endif
            if !quiet { NSApp.activate(ignoringOtherApps: true) }
            AppServices.shared.keyRouter.install()
            startSyncAfterFirstFrame()
        }
    }

    /// Starts the sync loop when the main thread first goes idle, which is after Core Animation
    /// committed the window's first frame (its run-loop observer is ordered before this one).
    private func startSyncAfterFirstFrame() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex(Int.max)) { _, _ in
            MainActor.assumeIsolated {
                Perf.mark("syncStart")
                AppServices.shared.sync.start()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppServices.shared.flush() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TodoTimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let services: AppServices

    init() {
        Perf.mark("appInit")
        services = AppServices.shared
    }

    var body: some Scene {
        Window("TodoTim", id: "main") {
            ContentView()
                .environment(services.model)
                .environment(services.store)
                .environment(services.sync)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1180, height: 820)
        .commands { AppCommands(model: services.model) }

        Settings {
            SettingsView()
                .environment(services.sync)
                .environment(services.model)
        }
    }
}
