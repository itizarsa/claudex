import Foundation

protocol CredentialItems: Sendable {
    func read(account: String) throws -> String?
    func write(account: String, value: String) throws
    func delete(account: String) throws
}

struct SystemCredentialItems: CredentialItems {
    private let service = "io.claudex.account"

    func read(account: String) throws -> String? {
        try KeychainItem.read(service: service, account: account)
    }

    func write(account: String, value: String) throws {
        try KeychainItem.write(service: service, account: account, value: value)
    }

    func delete(account: String) throws {
        _ = try KeychainItem.delete(service: service, account: account)
    }
}

/// One Keychain item per account, keyed by the local account UUID. A legacy file is consulted
/// only when the item is absent, then its entry is moved into the Keychain.
public struct KeychainCredentialStore: CredentialStore {
    private let items: any CredentialItems
    private let legacy: LegacyFileCredentialSource

    public init() {
        self.init(items: SystemCredentialItems(), legacyURL: Paths.vaultFile)
    }

    init(items: any CredentialItems, legacyURL: URL) {
        self.items = items
        self.legacy = LegacyFileCredentialSource(url: legacyURL)
    }

    public func store(_ credentials: Credentials, for id: UUID) throws {
        let data = try JSONEncoder.claudex.encode(credentials)
        try items.write(account: id.uuidString, value: String(decoding: data, as: UTF8.self))
    }

    public func load(_ id: UUID) throws -> Credentials? {
        if let value = try items.read(account: id.uuidString) {
            return try JSONDecoder.claudex.decode(Credentials.self, from: Data(value.utf8))
        }
        guard let migrated = try legacy.load(id) else { return nil }
        try store(migrated, for: id)
        try legacy.delete(id)
        return migrated
    }

    public func delete(_ id: UUID) throws {
        try items.delete(account: id.uuidString)
        try legacy.delete(id)
    }
}

/// The Keychain item Claude Code itself uses. Read in Phase 1; written in Phase 2, where it must
/// be kept in step with `~/.claude/.credentials.json` — the CLI reads the file first and a stale
/// file shadows a freshly written item.
enum ClaudeCLIKeychain {
    private static let service = "Claude Code-credentials"
    private static var account: String { NSUserName() }

    static func readRaw() throws -> Data? {
        try readRaw(service: service)
    }

    /// A sign-in run against a throwaway `CLAUDE_CONFIG_DIR` lands in its own item, so the
    /// service name is a parameter rather than the constant above.
    static func readRaw(service: String) throws -> Data? {
        let output = try SecurityCLI.run(["find-generic-password", "-s", service, "-a", account, "-w"])
        if output.exitCode == SecurityCLI.itemNotFound { return nil }
        guard output.exitCode == 0 else {
            throw ClaudexError.unsupportedAccount("Claude Code Keychain read failed (exit \(output.exitCode))")
        }
        let trimmed = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return decodeSecurityOutput(trimmed)
    }

    /// Every `Claude Code-credentials` item in the keychain, including the suffixed ones.
    ///
    /// Claude Code appends a hash of its config directory to the service name, so a sign-in run
    /// against a throwaway directory writes an item under a name claudex cannot compute.
    /// Comparing this set before and after the login is what identifies it. `dump-keychain`
    /// without `-d` prints attributes only, so no secret is read and no prompt is raised.
    static func credentialServices() throws -> Set<String> {
        let output = try SecurityCLI.run(["dump-keychain"])
        guard output.exitCode == 0 else { return [] }

        var found: Set<String> = []
        for line in output.standardOutput.split(separator: "\n") {
            guard let range = line.range(of: "\"svce\"<blob>=\"") else { continue }
            let rest = line[range.upperBound...]
            guard let end = rest.lastIndex(of: "\"") else { continue }
            let name = String(rest[..<end])
            if name.hasPrefix(service) { found.insert(name) }
        }
        return found
    }

    static func delete(service: String) throws {
        _ = try SecurityCLI.run(["delete-generic-password", "-s", service, "-a", account])
    }

    /// Unlike claudex's own items this value cannot be base64-wrapped — Claude Code expects the
    /// exact JSON bytes — so it cannot travel through `security -i`, whose parser would strip the
    /// quotes. It goes in the argument vector instead, where it is briefly visible to `ps`. The
    /// same token is already readable in `~/.claude/.credentials.json` by any process running as
    /// this user, so this widens the window rather than the audience.
    static func writeRaw(_ data: Data) throws {
        let output = try SecurityCLI.run([
            "add-generic-password", "-U", "-s", service, "-a", account,
            "-w", String(decoding: data, as: UTF8.self),
        ])
        guard output.exitCode == 0 else {
            throw ClaudexError.unsupportedAccount("Claude Code Keychain write failed (exit \(output.exitCode))")
        }
    }

    /// `security` prints a non-UTF8 payload as hex. Claude Code stores JSON text, so the hex form
    /// only shows up if that ever changes; decode it rather than hand back an unusable string.
    private static func decodeSecurityOutput(_ output: String) -> Data? {
        let isHex = output.count.isMultiple(of: 2)
            && !output.isEmpty
            && output.allSatisfy(\.isHexDigit)
        guard isHex else { return Data(output.utf8) }

        var bytes = [UInt8]()
        var index = output.startIndex
        while index < output.endIndex {
            let next = output.index(index, offsetBy: 2)
            guard let byte = UInt8(output[index..<next], radix: 16) else { return Data(output.utf8) }
            bytes.append(byte)
            index = next
        }
        let decoded = Data(bytes)
        return String(data: decoded, encoding: .utf8)?.hasPrefix("{") == true ? decoded : Data(output.utf8)
    }
}
