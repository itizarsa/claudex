import Foundation

/// One Keychain item per account, keyed by the local account UUID. Tokens never touch
/// `accounts.json`; that file holds only labels, emails and ordering.
enum KeychainVault {
    private static let service = "io.claudex.account"

    /// Belt and braces. `Vault` already routes to the file store when the Keychain is switched
    /// off, so this only catches a future call site that reaches past `Vault`.
    private static func assertEnabled() throws {
        guard Vault.useKeychain else {
            throw ClaudexError.unsupportedAccount("Keychain access is disabled")
        }
    }

    static func store(_ credentials: Credentials, for id: UUID) throws {
        try assertEnabled()
        let data = try JSONEncoder.claudex.encode(credentials)
        try KeychainItem.write(
            service: service,
            account: id.uuidString,
            value: String(decoding: data, as: UTF8.self)
        )
    }

    static func load(_ id: UUID) throws -> Credentials? {
        try assertEnabled()
        guard let value = try KeychainItem.read(service: service, account: id.uuidString) else {
            return nil
        }
        return try JSONDecoder.claudex.decode(Credentials.self, from: Data(value.utf8))
    }

    static func delete(_ id: UUID) throws {
        try assertEnabled()
        try KeychainItem.delete(service: service, account: id.uuidString)
    }
}

/// The Keychain item Claude Code itself uses. Read in Phase 1; written in Phase 2, where it must
/// be kept in step with `~/.claude/.credentials.json` — the CLI reads the file first and a stale
/// file shadows a freshly written item.
enum ClaudeCLIKeychain {
    private static let service = "Claude Code-credentials"
    private static var account: String { NSUserName() }

    static func readRaw() throws -> Data? {
        guard Vault.useKeychain else { return nil }
        let output = try SecurityCLI.run(["find-generic-password", "-s", service, "-a", account, "-w"])
        if output.exitCode == SecurityCLI.itemNotFound { return nil }
        guard output.exitCode == 0 else {
            throw ClaudexError.unsupportedAccount("Claude Code Keychain read failed (exit \(output.exitCode))")
        }
        let trimmed = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return decodeSecurityOutput(trimmed)
    }

    /// Unlike claudex's own items this value cannot be base64-wrapped — Claude Code expects the
    /// exact JSON bytes — so it cannot travel through `security -i`, whose parser would strip the
    /// quotes. It goes in the argument vector instead, where it is briefly visible to `ps`. The
    /// same token is already readable in `~/.claude/.credentials.json` by any process running as
    /// this user, so this widens the window rather than the audience.
    static func writeRaw(_ data: Data) throws {
        guard Vault.useKeychain else {
            throw ClaudexError.unsupportedAccount("Keychain access is disabled")
        }
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
