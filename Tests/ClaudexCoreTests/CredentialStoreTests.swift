import Foundation
import Testing
@testable import ClaudexCore

private final class MemoryCredentialItems: CredentialItems, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func read(account: String) -> String? { lock.withLock { values[account] } }
    func write(account: String, value: String) { lock.withLock { values[account] = value } }
    func delete(account: String) { lock.withLock { values[account] = nil } }
}

@Suite struct CredentialStoreTests {
    private func credential(_ token: String = "refresh") -> Credentials {
        .codex(CodexCredentials(
            idToken: "id",
            accessToken: "access",
            refreshToken: token,
            accountID: "account",
            lastRefresh: nil
        ))
    }

    @Test func inMemoryAdapterRoundTripsAndDeletes() throws {
        let id = UUID()
        let store = InMemoryCredentialStore()
        store.store(credential(), for: id)
        #expect(store.load(id) == credential())
        store.delete(id)
        #expect(store.load(id) == nil)
    }

    @Test func missingKeychainItemMigratesLegacyEntry() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "vault.json")
        let id = UUID()
        let value = credential()
        let data = try JSONEncoder.claudex.encode([id.uuidString: value])
        try data.write(to: legacyURL)

        let items = MemoryCredentialItems()
        let store = KeychainCredentialStore(items: items, legacyURL: legacyURL)
        #expect(try store.load(id) == value)
        #expect(items.read(account: id.uuidString) != nil)
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test func deleteClearsKeychainAndLegacyRemnants() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "vault.json")
        let id = UUID()
        let value = credential()
        try JSONEncoder.claudex.encode([id.uuidString: value]).write(to: legacyURL)

        let items = MemoryCredentialItems()
        items.write(account: id.uuidString, value: String(decoding: try JSONEncoder.claudex.encode(value), as: UTF8.self))
        let store = KeychainCredentialStore(items: items, legacyURL: legacyURL)
        try store.delete(id)

        #expect(items.read(account: id.uuidString) == nil)
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    }
}
