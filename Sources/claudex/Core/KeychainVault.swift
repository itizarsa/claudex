import Foundation
import Security

/// One Keychain item per account, keyed by the local account UUID. Tokens never touch
/// `accounts.json`; that file holds only labels, emails and ordering.
enum KeychainVault {
    private static let service = "io.claudex.account"

    /// Belt and braces. `Vault` already routes around the Keychain when it is disabled; this
    /// guard makes it structurally impossible for any future call site to reach a SecItem
    /// call and hang the app on an authorisation prompt.
    private static func assertEnabled() throws {
        guard Vault.useKeychain else {
            throw ClaudexError.unsupportedAccount("Keychain access is disabled")
        }
    }

    static func store(_ credentials: Credentials, for id: UUID) throws {
        try assertEnabled()
        let data = try JSONEncoder.claudex.encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ClaudexError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw ClaudexError.keychain(status)
        }
    }

    static func load(_ id: UUID) throws -> Credentials? {
        try assertEnabled()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ClaudexError.keychain(status)
        }
        return try JSONDecoder.claudex.decode(Credentials.self, from: data)
    }

    static func delete(_ id: UUID) throws {
        try assertEnabled()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClaudexError.keychain(status)
        }
    }
}

/// The Keychain item Claude Code itself uses. Read in Phase 1; written in Phase 2 and when
/// mirroring a refreshed token back to the active account.
enum ClaudeCLIKeychain {
    private static let service = "Claude Code-credentials"
    private static var account: String { NSUserName() }

    static func readRaw() throws -> Data? {
        // Reading an item owned by another application prompts for authorisation, so this is
        // unreachable unless the Keychain has been explicitly enabled.
        guard Vault.useKeychain else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ClaudexError.keychain(status)
        }
        return data
    }

    static func writeRaw(_ data: Data) throws {
        guard Vault.useKeychain else {
            throw ClaudexError.unsupportedAccount("Keychain access is disabled")
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ClaudexError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw ClaudexError.keychain(status)
        }
    }
}
