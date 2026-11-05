import Foundation
import TodoCore

/// The CalDAV password in the freedesktop Secret Service (GNOME Keyring on Omarchy), through
/// libsecret's `secret-tool`. Stored under the attributes `application=todotim` and
/// `account=<user@host[:port]>` (`SyncSettings.credentialAccount`), so a password saved for one
/// server is never sent to another. The password goes to `secret-tool` on stdin, never in argv.
public struct SecretToolCredentialStore: CredentialStore {
    public static let application = "todotim"
    public let executable: String
    public let timeout: TimeInterval

    public var storeName: String { "the keyring" }

    public init(executable: String = "secret-tool", timeout: TimeInterval = 30) {
        self.executable = executable
        self.timeout = timeout
    }

    public struct Failure: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    public func password(for account: String) -> String? {
        guard let result = try? Subprocess.run([executable, "lookup", "application", Self.application, "account", account],
                                               timeout: timeout),
              result.exitCode == 0,
              let text = String(data: result.stdout, encoding: .utf8) else { return nil }
        let password = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return password.isEmpty ? nil : password
    }

    public func setPassword(_ password: String?, for account: String) {
        try? savePassword(password, for: account)
    }

    public func savePassword(_ password: String?, for account: String) throws {
        let result: Subprocess.Result
        do {
            if let password, !password.isEmpty {
                result = try Subprocess.run([executable, "store", "--label=TodoTim (\(account))", "application",
                                             Self.application, "account", account],
                                            stdin: Data(password.utf8), timeout: timeout)
            } else {
                result = try Subprocess.run([executable, "clear", "application", Self.application, "account", account],
                                            timeout: timeout)
            }
        } catch {
            throw Failure(message: "secret-tool is not installed (pacman -S libsecret)")
        }
        if result.timedOut { throw Failure(message: "the keyring did not answer") }
        guard result.exitCode == 0 else { throw Failure(message: "secret-tool failed; is a keyring (gnome-keyring) running?") }
    }
}

/// `UserDefaults` for `SyncController` that keeps values in memory and reports writes, so the
/// engine stores its sync settings in its own `settings.json` and never touches a defaults domain.
final class EngineDefaults: UserDefaults {
    private var values: [String: Any]
    var onSet: ((String, Any?) -> Void)?

    init(values: [String: Any]) {
        self.values = values
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func stringArray(forKey defaultName: String) -> [String]? { values[defaultName] as? [String] }

    override func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
        onSet?(defaultName, value)
    }

    override func removeObject(forKey defaultName: String) {
        values[defaultName] = nil
        onSet?(defaultName, nil)
    }
}
