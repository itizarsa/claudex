import Foundation

/// The production `AccountRouting`: claudex's own account state, read once per request.
///
/// Reading the active pointer this late is the whole point of proxy mode. A CLI that started
/// before a switch still asks this object which account to use on its next request, so the
/// switch reaches a session already running without restarting it.
///
/// Proxy mode also inverts credential ownership. Under native file switching the CLI's active
/// credential belongs to the CLI, because a running process is holding it. Here the routed
/// processes hold only the local proxy token, so every routed credential is claudex's to
/// refresh and persist — including the active one.
@MainActor
public final class StoreAccountRouting: AccountRouting {
    private let store: AccountStore
    private let providers: ProviderRegistry
    /// Refresh rotates the refresh token, so two concurrent refreshes of one account race to
    /// invalidate each other. Sharing the in-flight task makes the second caller wait for the
    /// first rather than start a competing rotation.
    private var refreshes: [UUID: Task<Credentials, Error>] = [:]

    /// How close to expiry a token may be before the next request refreshes it first. Long
    /// enough to cover a slow round trip; short enough that it does not refresh constantly.
    private let leeway: TimeInterval = 120

    public init(store: AccountStore, providers: ProviderRegistry) {
        self.store = store
        self.providers = providers
    }

    public func resolve(_ kind: ProviderKind) async throws -> RoutedAccount {
        guard let account = store.activeAccount(for: kind), account.enabled else {
            throw ClaudexError.notSignedIn(kind)
        }
        guard let credentials = try store.credentials(for: account) else {
            throw ClaudexError.notSignedIn(kind)
        }

        let provider = try providers.provider(for: kind)
        guard provider.needsRefresh(credentials, leeway: leeway) else {
            return RoutedAccount(id: account.id, identity: account.identity, credentials: credentials)
        }
        let fresh = try await refreshed(account, provider: provider, from: credentials)
        return RoutedAccount(id: account.id, identity: account.identity, credentials: fresh)
    }

    public func refresh(_ kind: ProviderKind, rejecting rejected: RoutedAccount) async throws -> RoutedAccount? {
        guard let account = store.account(rejected.id),
              let stored = try store.credentials(for: account)
        else { return nil }

        // Someone already rotated this credential. The rejection describes a token that will
        // not be sent again, so retry with what is now on record and refresh nothing.
        guard stored.accessToken == rejected.credentials.accessToken else {
            return RoutedAccount(id: account.id, identity: account.identity, credentials: stored)
        }

        let provider = try providers.provider(for: kind)
        let fresh = try await refreshed(account, provider: provider, from: stored)
        return RoutedAccount(id: account.id, identity: account.identity, credentials: fresh)
    }

    public func observe(_ headers: [String: String], from account: RoutedAccount, kind: ProviderKind) async {
        // TODO: feed these into UsageEngine so a routed request updates the ring without
        // waiting for the next poll. Deliberately not wired yet: response headers and polled
        // snapshots disagree about window boundaries, and reconciling them is its own change.
        guard let remaining = headers["anthropic-ratelimit-unified-status"] ?? headers["x-codex-primary-used-percent"]
        else { return }
        Log.write("proxy: \(kind.rawValue) \(account.identity.email) limit \(remaining)")
    }

    /// Refreshes under a per-account in-flight task and persists before returning, so the
    /// credential the request path receives is the one on disk.
    private func refreshed(
        _ account: Account,
        provider: AnyProvider,
        from credentials: Credentials
    ) async throws -> Credentials {
        if let existing = refreshes[account.id] { return try await existing.value }

        let task = Task { @MainActor [store] () throws -> Credentials in
            let fresh = try await provider.refreshed(credentials)
            try store.storeCredentials(fresh, for: account)
            return fresh
        }
        refreshes[account.id] = task
        defer { refreshes[account.id] = nil }
        return try await task.value
    }
}

extension Credentials {
    /// The bearer the provider actually rejected. Compared, never logged.
    var accessToken: String {
        switch self {
        case .claude(let credential): return credential.accessToken
        case .codex(let credential): return credential.accessToken
        }
    }
}
