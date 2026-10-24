import Foundation

/// Optional dotfile configuration, `~/.todotim.toml` (override the path with `TODOTIM_CONFIG`).
/// When it has a `[sync]` table, those settings win over the ones saved from the Settings window,
/// so a dotfile manager such as chezmoi can configure the app. Example:
///
///     # TodoTim — https://github.com/timvink/todotim
///     repository = "https://github.com/timvink/todotim"
///
///     [sync]
///     enabled = true
///     server_url = "https://cloud.example.com/remote.php/dav/files/tim/"
///     username = "tim"
///     folder = "TodoTim"
///     # Prints the password; run once when the Keychain has none, then cached there.
///     password_command = "rbw get 'Nextcloud app password'"
public struct AppConfig: Equatable, Sendable {
    public static let defaultRepository = "https://github.com/timvink/todotim"

    public var repository: String
    /// nil when the file has no `[sync]` table.
    public var sync: SyncSettings?
    public var passwordCommand: String?

    public init(repository: String = AppConfig.defaultRepository, sync: SyncSettings? = nil, passwordCommand: String? = nil) {
        self.repository = repository; self.sync = sync; self.passwordCommand = passwordCommand
    }

    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["TODOTIM_CONFIG"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".todotim.toml")
    }

    public enum LoadError: Error, LocalizedError, Equatable {
        case invalid(path: String, reason: String)
        /// The file could be changed by someone else, so it is not used (it can run
        /// `password_command` and choose where the password is sent).
        case untrusted(path: String, reason: String)
        public var errorDescription: String? {
            switch self {
            case let .invalid(path, reason): "Could not read \(path): \(reason)"
            case let .untrusted(path, reason): "Not using \(path): \(reason)"
            }
        }
    }

    /// Largest config file read.
    static let maxFileSize = 1 << 20

    /// Returns nil when the file does not exist (also for a dangling symlink).
    ///
    /// The config can run a command and decides where the password is sent, so it is trusted like
    /// code: after resolving symlinks (chezmoi may use them) it must be a regular file owned by the
    /// current user and not writable by group or others, in a folder that others cannot write to
    /// (unless the folder is sticky, like /tmp). The same applies to `TODOTIM_CONFIG`.
    public static func load(from url: URL = defaultURL) throws -> AppConfig? {
        guard let data = try readTrusted(url.path) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            throw LoadError.invalid(path: url.path, reason: "not UTF-8")
        }
        do {
            return try parse(text)
        } catch let e as LocalizedError {
            throw LoadError.invalid(path: url.path, reason: e.errorDescription ?? "\(e)")
        }
    }

    /// Reads `path` after the trust checks described at `load`; nil when it does not exist.
    static func readTrusted(_ path: String) throws -> Data? {
        func posixError(_ what: String) -> LoadError {
            .invalid(path: path, reason: "\(what): \(String(cString: strerror(errno)))")
        }
        guard let resolvedC = realpath(path, nil) else {
            if errno == ENOENT { return nil }
            throw posixError("cannot resolve path")
        }
        let resolved = String(cString: resolvedC)
        free(resolvedC)
        let shown = (resolved as NSString).abbreviatingWithTildeInPath
        let fd = open(resolved, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("cannot open") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // Checks the opened file itself, so it cannot be swapped between check and read.
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw posixError("cannot inspect") }
        guard st.st_mode & S_IFMT == S_IFREG else {
            throw LoadError.untrusted(path: path, reason: "\(shown) is not a regular file")
        }
        guard st.st_uid == getuid() else {
            throw LoadError.untrusted(path: path, reason: "\(shown) is owned by another user")
        }
        guard st.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw LoadError.untrusted(path: path, reason: "\(shown) is writable by other users; run chmod 600 \(shown)")
        }
        // Folders: of the resolved file, and of the path as given (where a symlink may live).
        var folders = [(resolved as NSString).deletingLastPathComponent]
        let givenParent = ((path as NSString).deletingLastPathComponent as NSString).resolvingSymlinksInPath
        if givenParent != folders[0] { folders.append(givenParent) }
        for folder in folders {
            var ds = stat()
            guard stat(folder, &ds) == 0 else { throw posixError("cannot inspect \(folder)") }
            let shownFolder = (folder as NSString).abbreviatingWithTildeInPath
            guard ds.st_uid == getuid() || ds.st_uid == 0 else {
                throw LoadError.untrusted(path: path, reason: "its folder \(shownFolder) is owned by another user")
            }
            if ds.st_mode & (S_IWGRP | S_IWOTH) != 0 && ds.st_mode & S_ISVTX == 0 {
                throw LoadError.untrusted(path: path, reason: "its folder \(shownFolder) is writable by other users; run chmod go-w \(shownFolder)")
            }
        }
        guard st.st_size <= maxFileSize else {
            throw LoadError.invalid(path: path, reason: "larger than \(maxFileSize / 1024) KB")
        }
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw LoadError.invalid(path: path, reason: error.localizedDescription)
        }
    }

    public struct SchemaError: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    public static func parse(_ text: String) throws -> AppConfig {
        let values = try TOML.parse(text)
        let known: Set<String> = ["repository", "sync.enabled", "sync.server_url", "sync.username",
                                  "sync.folder", "sync.password_command"]
        if let unknown = values.keys.sorted().first(where: { !known.contains($0) }) {
            throw SchemaError(message: "Unknown key '\(unknown)'")
        }
        func string(_ key: String) throws -> String? {
            switch values[key] {
            case nil: return nil
            case let .string(s)?: return s
            default: throw SchemaError(message: "'\(key)' must be a string")
            }
        }
        var config = AppConfig(repository: try string("repository") ?? defaultRepository)
        if values.keys.contains(where: { $0.hasPrefix("sync.") }) {
            let enabled: Bool
            switch values["sync.enabled"] {
            case nil: enabled = true
            case let .bool(b)?: enabled = b
            default: throw SchemaError(message: "'sync.enabled' must be true or false")
            }
            config.sync = SyncSettings(serverURL: try string("sync.server_url") ?? "",
                                       username: try string("sync.username") ?? "",
                                       folder: try string("sync.folder") ?? "TodoTim",
                                       enabled: enabled)
            config.passwordCommand = try string("sync.password_command")
        }
        return config
    }
}

/// Runs `password_command` through the user's login shell, so tools from Homebrew are on PATH
/// even when the app is launched from Finder.
///
/// The command runs in its own process group. stdout and stderr are read concurrently and capped
/// at `maxOutput` bytes. On timeout or task cancellation the whole group gets SIGTERM, then
/// SIGKILL after `killGrace` seconds. Error messages never include the command's output, which
/// could contain secrets.
public enum PasswordCommand {
    public struct Failure: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    public static let maxOutput = 64 * 1024
    static let killGrace: TimeInterval = 2

    public static func run(_ command: String, timeout: TimeInterval = 60) async throws -> String {
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached { try runBlocking(command, timeout: timeout, cancelled: cancelled) }.value
        } onCancel: {
            cancelled.set()
        }
    }

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    static func runBlocking(_ command: String, timeout: TimeInterval, cancelled: CancelFlag) throws -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw Failure(message: "password_command could not start") }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw Failure(message: "password_command could not start")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Own process group (so the timeout can kill descendants); no other inherited fds;
        // default signal handling and an empty signal mask in the child.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                              | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for sig in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD, SIGALRM, SIGUSR1, SIGUSR2] {
            sigaddset(&defaultSignals, sig)
        }
        posix_spawnattr_setsigdefault(&attr, &defaultSignals)

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(shell), strdup("-lc"), strdup(command), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + envp { free(p) } }
        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, shell, &actions, &attr, argv, envp)
        close(outPipe[1]); close(errPipe[1])
        guard spawnStatus == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw Failure(message: "password_command could not start (\(String(cString: strerror(spawnStatus))))")
        }

        var stdout = Data(), stderrBytes = 0
        var openFDs: [Int32] = [outPipe[0], errPipe[0]]
        for fd in openFDs { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        defer { for fd in openFDs { close(fd) } }

        let start = Date()
        var termSentAt: Date?
        var timedOut = false, wasCancelled = false, tooMuchOutput = false
        var exitStatus: Int32?
        var exitedAt: Date?
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        func killGroup(_ sig: Int32) { _ = kill(-pid, sig) }

        while true {
            // Reap the shell as soon as it exits.
            if exitStatus == nil {
                var st: Int32 = 0
                if waitpid(pid, &st, WNOHANG) == pid { exitStatus = st; exitedAt = Date() }
            }
            // Done when the output is complete; after the shell exited, descendants that keep the
            // pipes open get one second before they are ignored.
            if exitStatus != nil && (openFDs.isEmpty || Date().timeIntervalSince(exitedAt!) > 1) { break }

            let elapsed = Date().timeIntervalSince(start)
            if termSentAt == nil, exitStatus == nil {
                if cancelled.isSet { wasCancelled = true } else if elapsed > timeout { timedOut = true }
                if wasCancelled || timedOut || tooMuchOutput {
                    killGroup(SIGTERM)
                    termSentAt = Date()
                }
            } else if let t = termSentAt, exitStatus == nil, Date().timeIntervalSince(t) > killGrace {
                killGroup(SIGKILL)
                var st: Int32 = 0
                if waitpid(pid, &st, 0) == pid { exitStatus = st; exitedAt = Date() }
                break
            }

            if openFDs.isEmpty {
                usleep(50_000)
                continue
            }
            var fds = openFDs.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            guard poll(&fds, nfds_t(fds.count), 50) > 0 else { continue }
            for p in fds where p.revents != 0 {
                let n = read(p.fd, &buffer, buffer.count)
                if n > 0 {
                    if p.fd == outPipe[0] {
                        if stdout.count + n > maxOutput { tooMuchOutput = true } else { stdout.append(contentsOf: buffer[0..<n]) }
                    } else {
                        stderrBytes += n  // drained and discarded: it may contain secrets
                    }
                } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                    close(p.fd)
                    openFDs.removeAll { $0 == p.fd }
                }
            }
        }
        _ = stderrBytes

        if wasCancelled { throw CancellationError() }
        if timedOut { throw Failure(message: "password_command timed out after \(Int(timeout.rounded())) s") }
        if tooMuchOutput { throw Failure(message: "password_command printed more than \(maxOutput / 1024) KB") }
        guard let status = exitStatus else { throw Failure(message: "password_command did not finish") }
        let signal = status & 0x7f
        if signal != 0 { throw Failure(message: "password_command was killed by signal \(signal)") }
        let code = (status >> 8) & 0xff
        guard code == 0 else { throw Failure(message: "password_command failed (exit \(code))") }
        let password = String(data: stdout, encoding: .utf8)?
            .components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !password.isEmpty else { throw Failure(message: "password_command printed nothing") }
        return password
    }
}
