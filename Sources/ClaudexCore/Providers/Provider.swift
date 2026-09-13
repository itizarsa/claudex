import Foundation

/// One seam per CLI. Everything provider-specific — endpoint shapes, credential file layout,
/// plan gating — sits behind this and nowhere else.
protocol Provider: Sendable {
    var kind: ProviderKind { get }

    func fetchUsage(_ credentials: Credentials) async throws -> UsageSnapshot
    func fetchIdentity(_ credentials: Credentials) async throws -> Identity
    func refresh(_ credentials: Credentials) async throws -> Credentials

    /// Whether the credentials should be refreshed before the next call.
    func needsRefresh(_ credentials: Credentials, leeway: TimeInterval) -> Bool

    /// Read whatever the CLI is signed into right now.
    func readCurrentCLICredentials() throws -> Credentials?

    /// Write credentials into the CLI's own storage. Phase 1 uses this only to mirror a
    /// refreshed token back to the account the CLI already holds.
    func activate(_ credentials: Credentials, identity: Identity) throws
}

enum Providers {
    static let claude = ClaudeProvider()
    static let codex = CodexProvider()

    static func of(_ kind: ProviderKind) -> Provider {
        switch kind {
        case .claude: return claude
        case .codex: return codex
        }
    }
}
