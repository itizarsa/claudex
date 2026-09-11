import Foundation

/// Where refresh tokens live.
///
/// The Keychain is the better store in principle, but it binds an item's access control to
/// the calling binary's code signature. A locally built, ad-hoc signed app gets a new
/// signature on every rebuild, so macOS treats each build as a different application and
/// blocks on an authorisation prompt — which a background poll or a CLI invocation can never
/// answer. Until claudex is signed with a stable identity, the default store is a 0600 file
/// inside the app's own container.
///
/// The exposure is the same as what already exists on the machine: Claude Code keeps its
/// tokens in `~/.claude/.credentials.json` and Codex in `~/.codex/auth.json`, both 0600 and
/// both readable by any process running as this user. The file vault adds no new class of
/// reader. It is still a real downgrade from the Keychain, which is why `Settings.useKeychain`
/// exists for anyone signing the app properly.
enum Vault {
    /// Read once at startup. Every Keychain entry point in the app checks this, so a single
    /// flag guarantees no code path can raise an authorisation prompt.
    static var useKeychain: Bool = Settings.load().allowKeychain

    static func store(_ credentials: Credentials, for id: UUID) throws {
        if useKeychain {
            try KeychainVault.store(credentials, for: id)
        } else {
            try FileVault.store(credentials, for: id)
        }
    }

    static func load(_ id: UUID) throws -> Credentials? {
        if useKeychain {
            return try KeychainVault.load(id)
        }
        return try FileVault.load(id)
    }

    static func delete(_ id: UUID) throws {
        if useKeychain {
            try KeychainVault.delete(id)
        } else {
            try FileVault.delete(id)
        }
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
