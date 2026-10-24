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
        public var errorDescription: String? {
            switch self {
            case let .invalid(path, reason): "Could not read \(path): \(reason)"
            }
        }
    }

    /// Returns nil when the file does not exist.
    public static func load(from url: URL = defaultURL) throws -> AppConfig? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            throw LoadError.invalid(path: url.path, reason: "not UTF-8")
        }
        do {
            return try parse(text)
        } catch let e as LocalizedError {
            throw LoadError.invalid(path: url.path, reason: e.errorDescription ?? "\(e)")
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
public enum PasswordCommand {
    public struct Failure: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    public static func run(_ command: String, timeout: TimeInterval = 60) async throws -> String {
        try await Task.detached {
            let process = Process()
            let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-lc", command]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            try process.run()
            // Kill a command that hangs (e.g. waiting for a vault unlock) so reads below return.
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            if process.terminationReason == .uncaughtSignal { throw Failure(message: "password_command timed out") }
            guard process.terminationStatus == 0 else {
                let detail = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw Failure(message: "password_command failed (exit \(process.terminationStatus))" + (detail.isEmpty ? "" : ": \(detail)"))
            }
            let password = String(data: outData, encoding: .utf8)?
                .components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !password.isEmpty else { throw Failure(message: "password_command printed nothing") }
            return password
        }.value
    }
}
