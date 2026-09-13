import Foundation

/// Storage seam for credentials owned by claudex. Production uses the Keychain; tests use the
/// in-memory adapter, so no test can reach a real account unless it explicitly constructs the
/// production adapter.
public protocol CredentialStore: Sendable {
    func store(_ credentials: Credentials, for id: UUID) throws
    func load(_ id: UUID) throws -> Credentials?
    func delete(_ id: UUID) throws
}

/// Thread-safe test and ephemeral adapter.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: Credentials]

    public init(_ entries: [UUID: Credentials] = [:]) {
        self.entries = entries
    }

    public func store(_ credentials: Credentials, for id: UUID) {
        lock.withLock { entries[id] = credentials }
    }

    public func load(_ id: UUID) -> Credentials? {
        lock.withLock { entries[id] }
    }

    public func delete(_ id: UUID) {
        lock.withLock { entries[id] = nil }
    }
}

/// Read-only compatibility source for credentials written before Keychain storage became the
/// only production path. Entries migrate on first read, then disappear from this file.
struct LegacyFileCredentialSource: Sendable {
    let url: URL

    func load(_ id: UUID) throws -> Credentials? {
        try readAll()[id.uuidString]
    }

    func delete(_ id: UUID) throws {
        var entries = try readAll()
        guard entries.removeValue(forKey: id.uuidString) != nil else { return }
        if entries.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        let data = try JSONEncoder.claudex.encode(entries)
        try AtomicFile.write(data, to: url)
    }

    private func readAll() throws -> [String: Credentials] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return try JSONDecoder.claudex.decode([String: Credentials].self, from: data)
    }
}
