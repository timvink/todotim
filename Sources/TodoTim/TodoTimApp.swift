import AppKit
import SwiftUI
import TodoCore

/// Owns the store, sync controller and persistence. Created once at launch.
///
/// Environment variables (for development and screenshots):
/// - `TODOTIM_DATA_DIR`: directory holding `db.json` instead of Application Support. Sync
///   settings then come from a separate UserDefaults suite (`nl.timvink.todotim.dev`), so
///   test data never syncs to the server configured for the real database.
/// - `TODOTIM_SEED=1`: inserts sample data when the database has no tasks.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let store: TodoStore
    let sync: SyncController
    let model: AppModel
    let dbURL: URL
    private var saveTask: Task<Void, Never>?
    let keyRouter: KeyRouter

    private init() {
        let env = ProcessInfo.processInfo.environment
        let customDir = env["TODOTIM_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        if let customDir {
            dbURL = URL(fileURLWithPath: (customDir as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("db.json")
        } else {
            dbURL = LocalPersistence.fileURL
        }
        store = TodoStore(db: LocalPersistence.load(from: dbURL))
        if env["TODOTIM_SEED"] == "1", store.db.tasks.isEmpty {
            SampleData.seed(store)
            try? LocalPersistence.save(store.db, to: dbURL)
        }
        let defaults = customDir == nil ? UserDefaults.standard : (UserDefaults(suiteName: "nl.timvink.todotim.dev") ?? .standard)
        sync = SyncController(store: store, defaults: defaults)
        model = AppModel(store: store, sync: sync)
        keyRouter = KeyRouter(model: model)

        store.onLocalChange = { [weak self] in
            guard let self else { return }
            self.scheduleSave()
            self.sync.scheduleSync()
        }
        // A sync merge replaces the database without calling `onLocalChange`; persist it too.
        sync.onDatabaseReplaced = { [weak self] in self?.scheduleSave() }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do {
            try LocalPersistence.save(store.db, to: dbURL)
        } catch {
            NSLog("TodoTim: failed to save database: \(error)")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            AppServices.shared.keyRouter.install()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppServices.shared.saveNow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TodoTimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let services = AppServices.shared

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
