import Foundation

/// Sign a CLI into a different stored account.
///
/// The order of the three steps matters more than any of them individually, because refresh
/// tokens rotate: whichever copy is written last is the only one that still works. Harvest the
/// outgoing account first, persist the incoming account's refreshed tokens before handing them
/// to the CLI, and only then record the change.
enum Switcher {
    /// Returns false when the account was already active, so a caller reporting the outcome can
    /// tell a switch from a no-op rather than announcing one for the other.
    @MainActor
    @discardableResult
    static func activate(_ account: Account, in store: AccountStore) async throws -> Bool {
        guard !store.isActive(account) else { return false }
        let provider = Providers.of(account.provider)

        try harvestOutgoing(account.provider, provider: provider, store: store)

        guard var credentials = try store.credentials(for: account) else {
            throw ClaudexError.notSignedIn(account.provider)
        }

        // Refresh before activating rather than leaving it to the CLI. The CLI would manage, but
        // a switch that hands over an expired token looks like a failed switch, and the rotated
        // token would then live only in the CLI's store until the next harvest.
        if provider.needsRefresh(credentials, leeway: 300) {
            credentials = try await provider.refresh(credentials)
            try store.storeCredentials(credentials, for: account)
        }

        try provider.activate(credentials, identity: account.identity)
        store.setActive(account)
        return true
    }

    /// The CLI owns the active account's tokens, so it holds refreshes claudex never saw. Copy
    /// them back before they are overwritten; without this, switching away from an account
    /// silently invalidates it.
    @MainActor
    private static func harvestOutgoing(
        _ kind: ProviderKind,
        provider: Provider,
        store: AccountStore
    ) throws {
        guard let outgoing = store.activeAccount(for: kind),
              let live = try provider.readCurrentCLICredentials()
        else { return }
        try store.storeCredentials(live, for: outgoing)
    }
}
