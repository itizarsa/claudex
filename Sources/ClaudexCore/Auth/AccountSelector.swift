import Foundation

public protocol AccountSelecting: Sendable {
    @MainActor
    func select(_ account: Account) async throws -> Bool
}

/// Selects which vaulted account the proxy uses for each new request. It never reads or writes
/// provider CLI credential storage.
@MainActor
public final class AccountSelector: AccountSelecting {
    private let store: AccountStore

    public init(store: AccountStore) {
        self.store = store
    }

    /// Returns false when the proxy already routes this provider through the requested account.
    @discardableResult
    public func select(_ account: Account) async throws -> Bool {
        guard !store.isActive(account) else { return false }
        guard try store.credentials(for: account) != nil else {
            throw ClaudexError.notSignedIn(account.provider)
        }
        store.setActive(account)
        return true
    }
}
