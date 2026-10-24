import Foundation
import Security

/// Where the WebDAV password is kept. The default is the Keychain; tests use an in-memory one.
public protocol CredentialStore: Sendable {
    func password(for account: String) -> String?
    func setPassword(_ password: String?, for account: String)
}

/// Generic-password Keychain items with service "TodoTim WebDAV" and account = username.
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

    /// nil or empty deletes the item.
    public func setPassword(_ password: String?, for account: String) {
        guard !account.isEmpty else { return }
        let query = baseQuery(account)
        guard let password, !password.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = service
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// In-memory credential store (tests, previews).
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [String: String] = [:]

    public init(_ passwords: [String: String] = [:]) { self.passwords = passwords }

    public func password(for account: String) -> String? { lock.withLock { passwords[account] } }
    public func setPassword(_ password: String?, for account: String) {
        lock.withLock { passwords[account] = (password?.isEmpty ?? true) ? nil : password }
    }
}
