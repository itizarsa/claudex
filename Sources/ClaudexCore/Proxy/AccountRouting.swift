import Foundation

/// One account resolved for one request: who it is, and the credential to spend on it.
public struct RoutedAccount: Sendable, Equatable {
    public let id: UUID
    public let identity: Identity
    public let credentials: Credentials

    public init(id: UUID, identity: Identity, credentials: Credentials) {
        self.id = id
        self.identity = identity
        self.credentials = credentials
    }
}

/// The proxy's window onto claudex's account state.
///
/// A protocol rather than a direct `AccountStore` reference for two reasons. The store is
/// `@MainActor` and the request path runs on the server's own threads, so every read has to
/// cross that boundary anyway and it is worth naming which reads exist. And a proxy test
/// should not need a Keychain, a real subscription, or a main run loop.
public protocol AccountRouting: Sendable {
    /// The account the request beginning now should use, refreshed if its token is close to
    /// expiry. Called per request and never cached by the proxy: reading the pointer late is
    /// exactly what lets a switch reach a session that is already running.
    func resolve(_ kind: ProviderKind) async throws -> RoutedAccount

    /// What to retry with after the provider rejected `rejected`'s access token.
    ///
    /// Only forces a refresh when the rejected token is still the one on record. A 401 that
    /// names a token some other request already replaced is stale news, and acting on it would
    /// discard a working credential; in that case the caller simply gets the current one.
    ///
    /// Returns nil when there is nothing better to send, which the caller must read as "give
    /// the client the 401" rather than as an invitation to try again.
    func refresh(_ kind: ProviderKind, rejecting rejected: RoutedAccount) async throws -> RoutedAccount?

    /// Rate-limit headers from a response that `account` served. Attributed to the account
    /// that actually served it, which after a retry is not the account the request started on.
    func observe(_ headers: [String: String], from account: RoutedAccount, kind: ProviderKind) async
}

/// Fixed routing for tests and for a dry run against a recorded backend.
public final class StaticAccountRouting: AccountRouting, @unchecked Sendable {
    private let lock = NSLock()
    private var accounts: [ProviderKind: RoutedAccount]
    /// Every header set handed to `observe`, in arrival order, so a test can assert what the
    /// proxy attributed to whom.
    public private(set) var observed: [(ProviderKind, UUID, [String: String])] = []

    public init(_ accounts: [ProviderKind: RoutedAccount]) {
        self.accounts = accounts
    }

    public func resolve(_ kind: ProviderKind) throws -> RoutedAccount {
        guard let account = lock.withLock({ accounts[kind] }) else {
            throw ClaudexError.notSignedIn(kind)
        }
        return account
    }

    public func refresh(_ kind: ProviderKind, rejecting rejected: RoutedAccount) throws -> RoutedAccount? {
        let current = try resolve(kind)
        return current == rejected ? nil : current
    }

    public var observedHeaders: [[String: String]] { lock.withLock { observed.map(\.2) } }

    public func observe(_ headers: [String: String], from account: RoutedAccount, kind: ProviderKind) {
        lock.withLock { observed.append((kind, account.id, headers)) }
    }

    public func set(_ account: RoutedAccount, for kind: ProviderKind) {
        lock.withLock { accounts[kind] = account }
    }
}
