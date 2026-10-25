import Foundation
#if canImport(Security)
import Security
#endif

/// Where the WebDAV password is kept. The default is the Keychain; tests use an in-memory one.
/// Accounts are `SyncSettings.credentialAccount` ("user@host[:port]"), so a password is only
/// ever used for the server it was saved for.
public protocol CredentialStore: Sendable {
    func password(for account: String) -> String?
    /// Saves (nil or empty: deletes) the password. Prefer `savePassword`, which reports failures.
    func setPassword(_ password: String?, for account: String)
    /// Like `setPassword`, but throws when the password could not be stored.
    func savePassword(_ password: String?, for account: String) throws
}

extension CredentialStore {
    public func savePassword(_ password: String?, for account: String) throws {
        setPassword(password, for: account)
    }
}

// The Keychain exists only on Apple platforms; TodoCore also builds on Linux for tests.
#if canImport(Security)
public struct KeychainError: Error, LocalizedError, Equatable, Sendable {
    public var status: OSStatus
    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "Keychain: \(detail) (\(status))"
    }
}

/// Generic-password Keychain items with service "TodoTim WebDAV" and account = `user@host[:port]`.
/// Items from older versions (account = username only) are not used: they did not record which
/// server they belong to. `password_command` or the Settings window fills the new item.
public struct KeychainCredentialStore: CredentialStore {
    public static let service = "TodoTim WebDAV"
    public let service: String

    public init(service: String = KeychainCredentialStore.service) { self.service = service }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func password(for account: String) -> String? {
        guard !account.isEmpty else { return nil }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String?, for account: String) {
        do {
            try savePassword(password, for: account)
        } catch {
            NSLog("TodoTim: could not save password: \(error.localizedDescription)")
        }
    }

    /// nil or empty deletes the item.
    public func savePassword(_ password: String?, for account: String) throws {
        guard !account.isEmpty else { return }
        let query = baseQuery(account)
        guard let password, !password.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(password.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "\(service) (\(account))"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
#endif

/// In-memory credential store (tests, previews).
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [String: String] = [:]
    /// When set, `savePassword` throws it (for tests).
    public var saveError: Error?

    public init(_ passwords: [String: String] = [:]) { self.passwords = passwords }

    public func password(for account: String) -> String? { lock.withLock { passwords[account] } }
    public func setPassword(_ password: String?, for account: String) {
        lock.withLock { passwords[account] = (password?.isEmpty ?? true) ? nil : password }
    }
    public func savePassword(_ password: String?, for account: String) throws {
        if let saveError = lock.withLock({ saveError }) { throw saveError }
        setPassword(password, for: account)
    }
}
