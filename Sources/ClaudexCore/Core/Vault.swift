import Foundation

/// Where refresh tokens live.
///
/// The Keychain, reached through `/usr/bin/security` rather than the Security framework. The
/// framework route is unusable from a locally built app: it binds an item's access control to
/// the calling binary's code signature, an ad-hoc signed build gets a new signature on every
/// rebuild, so macOS treats each build as a different application and blocks on an authorisation
/// prompt that a background poll can never answer. `/usr/bin/security` is Apple-signed with a
/// stable identity and completes the same operations unprompted. See `SecurityCLI`.
///
/// `Settings.allowKeychain` switches the whole app back to a 0600 file in its own container,
/// which is where tokens lived before the subprocess route was found.
enum Vault {
    /// Read once at startup, so a single flag decides the store for every call site.
    static var useKeychain: Bool = Settings.load().allowKeychain

    static func store(_ credentials: Credentials, for id: UUID) throws {
        if useKeychain {
            try KeychainVault.store(credentials, for: id)
        } else {
            try FileVault.store(credentials, for: id)
        }
    }

    /// Reads fall back to the file store and migrate what they find: accounts stored before the
    /// Keychain became usable would otherwise read as signed out.
    static func load(_ id: UUID) throws -> Credentials? {
        guard useKeychain else { return try FileVault.load(id) }
        if let stored = try KeychainVault.load(id) { return stored }
        guard let migrated = try FileVault.load(id) else { return nil }
        try KeychainVault.store(migrated, for: id)
        try FileVault.delete(id)
        return migrated
    }

    /// Clears both stores whichever is active: a half-migrated account must not leave a live
    /// token behind in the one currently switched off.
    static func delete(_ id: UUID) throws {
        if useKeychain {
            try KeychainVault.delete(id)
        }
        try FileVault.delete(id)
    }
}

enum FileVault {
    private static func readAll() throws -> [String: Credentials] {
        guard let data = try? Data(contentsOf: Paths.vaultFile) else { return [:] }
        return (try? JSONDecoder.claudex.decode([String: Credentials].self, from: data)) ?? [:]
    }

    private static func writeAll(_ entries: [String: Credentials]) throws {
        try Paths.ensureSupportDirectory()
        let data = try JSONEncoder.claudex.encode(entries)
        try AtomicFile.write(data, to: Paths.vaultFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: Paths.vaultFile.path
        )
    }

    static func store(_ credentials: Credentials, for id: UUID) throws {
        var entries = try readAll()
        entries[id.uuidString] = credentials
        try writeAll(entries)
    }

    static func load(_ id: UUID) throws -> Credentials? {
        try readAll()[id.uuidString]
    }

    static func delete(_ id: UUID) throws {
        var entries = try readAll()
        entries[id.uuidString] = nil
        try writeAll(entries)
    }
}
