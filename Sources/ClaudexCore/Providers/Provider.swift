import Foundation

/// The remote half of a CLI: what the vendor's API will say about a credential. Talks to the
/// network and touches no files.
///
/// Split from `CLISession` because the two fail for unrelated reasons and are substituted
/// separately: a test of the poll path wants a canned API and the real files, a test of a
/// switch wants the real rules and a throwaway directory. One seam covering both could give
/// neither.
public protocol UsageAPI: Sendable {
    associatedtype Credential: ProviderCredential

    func usage(_ credential: Credential) async throws -> UsageSnapshot
    func identity(_ credential: Credential) async throws -> Identity
    func refreshed(_ credential: Credential) async throws -> Credential

    /// Whether the credential should be refreshed before the next call.
    func needsRefresh(_ credential: Credential, leeway: TimeInterval) -> Bool
}

/// The local half of a CLI: the credential store it keeps on disk, and the config it reads its
/// identity from. Touches files and no network.
public protocol CLISession: Sendable {
    associatedtype Credential: ProviderCredential

    /// What the CLI is signed into right now; nil when it is signed out.
    func current() throws -> Credential?

    /// The credential shape, wherever the bytes came from: the CLI's own store, its Keychain
    /// item, or the throwaway directory a sandboxed sign-in writes. Nil when the bytes are a
    /// credential store with nothing signed in.
    func parse(_ data: Data) throws -> Credential?

    /// Write a credential into the CLI's own storage, so the next `current()` reads it back.
    func activate(_ credential: Credential, identity: Identity) throws
}

/// The store keeps every provider's credentials in one shape; each half above works in its own.
/// This is where the two meet, and the only place either conversion happens.
public protocol ProviderCredential: Sendable, Equatable {
    init(unboxing credentials: Credentials) throws
    var boxed: Credentials { get }
}

extension ClaudeCredentials: ProviderCredential {
    public init(unboxing credentials: Credentials) throws {
        guard case .claude(let value) = credentials else {
            throw ClaudexError.unsupportedAccount("Expected Claude credentials")
        }
        self = value
    }

    public var boxed: Credentials { .claude(self) }
}

extension CodexCredentials: ProviderCredential {
    public init(unboxing credentials: Credentials) throws {
        guard case .codex(let value) = credentials else {
            throw ClaudexError.unsupportedAccount("Expected Codex credentials")
        }
        self = value
    }

    public var boxed: Credentials { .codex(self) }
}

/// One CLI's two halves, speaking `Credentials` on the outside so the poll path and the
/// switcher can hold either provider without naming which. Unboxing happens here and nowhere
/// else: below this line each half works in its own credential shape.
public struct AnyProvider: Sendable {
    public let kind: ProviderKind

    private let _usage: @Sendable (Credentials) async throws -> UsageSnapshot
    private let _identity: @Sendable (Credentials) async throws -> Identity
    private let _refreshed: @Sendable (Credentials) async throws -> Credentials
    private let _needsRefresh: @Sendable (Credentials, TimeInterval) -> Bool
    private let _current: @Sendable () throws -> Credentials?
    private let _parse: @Sendable (Data) throws -> Credentials?
    private let _activate: @Sendable (Credentials, Identity) throws -> Void

    public init<API: UsageAPI, CLI: CLISession>(
        kind: ProviderKind,
        api: API,
        cli: CLI
    ) where API.Credential == CLI.Credential {
        typealias Credential = API.Credential
        self.kind = kind
        _usage = { try await api.usage(Credential(unboxing: $0)) }
        _identity = { try await api.identity(Credential(unboxing: $0)) }
        _refreshed = { try await api.refreshed(Credential(unboxing: $0)).boxed }
        // Not a credential this provider understands is not a credential due a refresh; the
        // mismatch surfaces on the next call that can report it.
        _needsRefresh = { credentials, leeway in
            guard let credential = try? Credential(unboxing: credentials) else { return false }
            return api.needsRefresh(credential, leeway: leeway)
        }
        _current = { try cli.current()?.boxed }
        _parse = { try cli.parse($0)?.boxed }
        _activate = { try cli.activate(Credential(unboxing: $0), identity: $1) }
    }

    public func usage(_ credentials: Credentials) async throws -> UsageSnapshot {
        try await _usage(credentials)
    }

    public func identity(_ credentials: Credentials) async throws -> Identity {
        try await _identity(credentials)
    }

    public func refreshed(_ credentials: Credentials) async throws -> Credentials {
        try await _refreshed(credentials)
    }

    public func needsRefresh(_ credentials: Credentials, leeway: TimeInterval) -> Bool {
        _needsRefresh(credentials, leeway)
    }

    /// Read whatever the CLI is signed into right now.
    public func currentCLICredentials() throws -> Credentials? { try _current() }

    public func parseCLICredentials(_ data: Data) throws -> Credentials? { try _parse(data) }

    public func activate(_ credentials: Credentials, identity: Identity) throws {
        try _activate(credentials, identity)
    }
}

/// Provider selection is assembled once and injected into callers. Tests can replace either
/// half of one provider without touching production files or endpoints.
public struct ProviderRegistry: Sendable {
    private let providers: [ProviderKind: AnyProvider]

    public init(_ providers: [AnyProvider]) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.kind, $0) })
    }

    public func provider(for kind: ProviderKind) throws -> AnyProvider {
        guard let provider = providers[kind] else {
            throw ClaudexError.unsupportedAccount("No provider registered for \(kind.displayName)")
        }
        return provider
    }

    /// Production adapters. Calling this is a composition-root decision, never a domain-module
    /// default, so tests cannot silently reach real endpoints or CLI credential files.
    public static func live() -> ProviderRegistry {
        ProviderRegistry([
            AnyProvider(kind: .claude, api: ClaudeAPI(), cli: ClaudeCLI()),
            AnyProvider(kind: .codex, api: CodexAPI(), cli: CodexCLI()),
        ])
    }
}
