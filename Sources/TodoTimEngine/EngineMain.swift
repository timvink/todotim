import Foundation
import TodoCore
#if canImport(Glibc)
import Glibc
#endif

/// The `todotim-engine` process: one engine per data folder (a lock file), requests on stdin,
/// replies and events on stdout, diagnostics on stderr. It exits after writing the database when
/// stdin closes (the UI quit) or on SIGTERM, SIGINT or SIGHUP.
public enum EngineMain {
    static let usage = """
        Usage: todotim-engine [--data-dir DIR] [--seed-demo] [--no-sync]
               todotim-engine --version

        Runs the TodoTim engine for the Omarchy plugin: JSON lines on stdin and stdout.
          --data-dir DIR  keep db.json and the other files in DIR (default: $TODOTIM_DATA_DIR,
                          else $XDG_DATA_HOME/todotim, else ~/.local/share/todotim)
          --seed-demo     fill an empty database with demo tasks
          --no-sync       read no ~/.todotim.toml and do not sync until sync is set up in the app

        """

    nonisolated(unsafe) private static var keepAlive: [Any] = []
    nonisolated(unsafe) private static var lockFD: Int32 = -1

    public static func run(arguments: [String]) -> Never {
        var dataDir: String?
        var seedDemo = false
        var noSync = false
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--version":
                print(Engine.version)
                exit(0)
            case "--help", "-h":
                print(usage, terminator: "")
                exit(0)
            case "--data-dir":
                i += 1
                guard i < arguments.count else { fail("--data-dir needs a folder", code: 64) }
                dataDir = arguments[i]
            case "--seed-demo":
                seedDemo = true
            case "--no-sync":
                noSync = true
            default:
                fail("unknown argument \(arguments[i])\n\n" + usage, code: 64)
            }
            i += 1
        }
        signal(SIGPIPE, SIG_IGN)
        let env = ProcessInfo.processInfo.environment
        let paths = EnginePaths.resolve(explicit: dataDir, environment: env)
        try? FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard acquireLock(paths.lock) else {
            writeLine((["event": "fatal", "error": .string("Another TodoTim engine is using \(paths.dataDir.path)")] as JSON).serialized())
            fail("another engine is using \(paths.dataDir.path)", code: 75)
        }

        // As in the Mac app: with a custom data folder, ~/.todotim.toml is only read when
        // TODOTIM_CONFIG names a config explicitly, so test data never syncs to the real server.
        let customDir = dataDir != nil || !(env["TODOTIM_DATA_DIR"] ?? "").isEmpty
        var config: AppConfig?
        var configError: String?
        if !noSync, !customDir || !(env["TODOTIM_CONFIG"] ?? "").isEmpty {
            do {
                config = try AppConfig.load(from: AppConfig.defaultURL)
            } catch {
                configError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        let engine: Engine = MainActor.assumeIsolated {
            let engine = Engine(paths: paths, credentials: credentialStore(), config: config,
                                configPath: AppConfig.defaultURL.path, configError: configError,
                                startSyncing: !noSync, output: writeLine)
            if seedDemo, engine.store.db.tasks.isEmpty {
                DemoData.seed(engine.store)
                engine.flush()
            }
            engine.startDayTimer()
            return engine
        }
        keepAlive.append(engine)

        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { engine.flush() }
                exit(0)
            }
            source.resume()
            keepAlive.append(source)
        }

        let reader = Thread {
            readLines(from: STDIN_FILENO) { line in
                DispatchQueue.main.async { MainActor.assumeIsolated { engine.handle(line) } }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { engine.flush() }
                exit(0)
            }
        }
        reader.start()
        keepAlive.append(reader)
        dispatchMain()
    }

    /// Calls `body` with each line read from `fd` (without "\n" or "\r\n"), until end of file or a
    /// read error; a last line without a newline counts too.
    ///
    /// With read(2), not `readLine`: stdio holds stdin's lock while `readLine` waits for input, and
    /// `exit` takes every stdio lock (musl's `__stdio_exit`), so a SIGTERM, SIGINT or SIGHUP left the
    /// engine hung in `exit` forever: alive, holding the data folder's lock, its main queue blocked
    /// (no replies, no sync), and deaf to further signals.
    static func readLines(from fd: Int32, _ body: (String) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pending: [UInt8] = []
        func emit(_ bytes: ArraySlice<UInt8>) {
            var line = bytes
            if line.last == 13 { line = line.dropLast() }
            body(String(decoding: line, as: UTF8.self))
        }
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            pending.append(contentsOf: buffer[0..<n])
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 10) {
                emit(pending[start..<newline])
                start = newline + 1
            }
            pending.removeSubrange(..<start)
        }
        if !pending.isEmpty { emit(pending[...]) }
    }

    static func credentialStore() -> CredentialStore {
        #if os(Linux)
        SecretToolCredentialStore()
        #else
        // The engine on macOS is for development only; it does not share the Mac app's Keychain item.
        InMemoryCredentialStore()
        #endif
    }

    /// One protocol line on stdout. Errors (the UI went away) are ignored: stdin then closes too.
    static func writeLine(_ line: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }

    static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("todotim-engine: \(message)\n".utf8))
        exit(code)
    }

    /// Holds an exclusive lock on `url` for the life of the process. Waits up to five seconds for a
    /// previous engine (from a shell that is restarting) to exit.
    static func acquireLock(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        for _ in 0..<50 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                lockFD = fd
                return true
            }
            usleep(100_000)
        }
        close(fd)
        return false
    }
}
