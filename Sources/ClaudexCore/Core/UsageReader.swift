import Foundation

/// Returns one exact provider reading while owning every credential rule needed to obtain it.
/// Callers never decide which credential source to trust, when to refresh, or which rotated
/// credential must be persisted.
@MainActor
public final class UsageReader {
    private let store: AccountStore
    private let providers: ProviderRegistry
    private var rateLimitRecovery = RateLimitRecovery()
    private let refreshLeeway: TimeInterval

    public init(
        store: AccountStore,
        providers: ProviderRegistry,
        refreshLeeway: TimeInterval = 300
    ) {
        self.store = store
        self.providers = providers
        self.refreshLeeway = refreshLeeway
    }

    public func reading(for account: Account) async throws -> UsageSnapshot {
        let provider = try providers.provider(for: account.provider)
        do {
            let snapshot = try await read(account, with: provider)
            rateLimitRecovery.reset(account.id)
            return snapshot
        } catch {
            if (error as? ClaudexError)?.httpStatus != 429 {
                rateLimitRecovery.reset(account.id)
            }
            throw error
        }
    }

    /// Routed CLIs carry only a local proxy token. Claudex's vault therefore owns active and
    /// inactive provider credentials alike.
    private func read(_ account: Account, with provider: AnyProvider) async throws -> UsageSnapshot {
        guard var credentials = try store.credentials(for: account) else {
            throw ClaudexError.unsupportedAccount("No stored credentials for \(account.label)")
        }

        if provider.needsRefresh(credentials, leeway: refreshLeeway) {
            credentials = try await refreshAndStore(provider, credentials, account)
        }

        do {
            return try await provider.usage(credentials)
        } catch let error as ClaudexError where error.isUnauthorized {
            let renewed = try await refreshAndStore(provider, credentials, account)
            return try await provider.usage(renewed)
        } catch let error as ClaudexError where error.httpStatus == 429 {
            guard rateLimitRecovery.shouldRefreshAfterRateLimit(for: account.id) else { throw error }
            let renewed = try await refreshAndStore(provider, credentials, account)
            return try await provider.usage(renewed)
        }
    }

    private func refreshAndStore(
        _ provider: AnyProvider,
        _ credentials: Credentials,
        _ account: Account
    ) async throws -> Credentials {
        let renewed = try await provider.refreshed(credentials)
        try store.storeCredentials(renewed, for: account)
        return renewed
    }
}
