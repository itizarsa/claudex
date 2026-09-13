import Foundation

public protocol AccountSwitching: Sendable {
    @MainActor
    func activate(_ account: Account) async throws -> Bool
}

/// Signs one CLI into a stored account. The module owns the full ordering because refresh-token
/// rotation makes partial orchestration by callers unsafe.
@MainActor
public final class Switcher: AccountSwitching {
    private let store: AccountStore
    private let providers: ProviderRegistry

    public init(store: AccountStore, providers: ProviderRegistry) {
        self.store = store
        self.providers = providers
    }

    /// Harvest current CLI state, persist any incoming refresh, activate, then record the new
    /// active account. Returns false when the CLI already holds the requested account.
    @discardableResult
    public func activate(_ account: Account) async throws -> Bool {
        let provider = try providers.provider(for: account.provider)
        try await harvestCurrent(account.provider, provider: provider)
        guard !store.isActive(account) else { return false }

        guard var credentials = try store.credentials(for: account) else {
            throw ClaudexError.notSignedIn(account.provider)
        }

        if provider.needsRefresh(credentials, leeway: 300) {
            credentials = try await provider.refreshed(credentials)
            try store.storeCredentials(credentials, for: account)
        }

        try provider.activate(credentials, identity: account.identity)
        store.setActive(account)
        return true
    }

    /// Reconciles claudex's active pointer with live CLI state before overwriting that state.
    /// Exact stored matches need no network. A rotated or externally replaced credential is
    /// identified remotely; an untracked account stops the switch instead of corrupting the
    /// credential saved under claudex's stale active pointer.
    private func harvestCurrent(_ kind: ProviderKind, provider: AnyProvider) async throws {
        guard let live = try provider.currentCLICredentials() else { return }

        if let exact = try store.accounts(for: kind).first(where: {
            try store.credentials(for: $0)?.refreshFingerprint == live.refreshFingerprint
        }) {
            try store.storeCredentials(live, for: exact)
            if !store.isActive(exact) { store.setActive(exact) }
            return
        }

        let identity = try await provider.identity(live)
        guard let actual = store.existing(matching: identity, kind: kind) else {
            throw ClaudexError.unsupportedAccount(
                "\(kind.displayName) CLI is signed into an untracked account. Add it before switching."
            )
        }
        try store.storeCredentials(live, for: actual)
        if !store.isActive(actual) { store.setActive(actual) }
    }
}
