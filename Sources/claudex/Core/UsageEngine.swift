import AppKit
import Foundation
import Observation

/// Owns polling, token refresh and the per-account backoff. Nothing here writes to the CLIs.
///
/// Refresh tokens rotate: the token endpoint issues a new one and retires the old. That makes
/// refreshing the account a CLI is currently signed into unsafe, because claudex cannot hand
/// the replacement back — Claude Code also keeps a copy in a Keychain item, and writing
/// another application's Keychain item raises an authorisation prompt that a background poll
/// can never answer. So the active account is treated as owned by the CLI: its credentials
/// are re-read from disk on every poll, and the CLI is left to refresh its own tokens.
/// Inactive accounts are owned by claudex and refreshed here.
@MainActor
@Observable
final class UsageEngine {
    private let store: AccountStore
    let notifier: Notifier
    let rotator: Rotator
    private var timer: Timer?
    private var lastPolled: [UUID: Date] = [:]
    private var backoffUntil: [UUID: Date] = [:]
    private var failureCount: [UUID: Int] = [:]
    private var inFlight: Set<UUID> = []

    private let refreshLeeway: TimeInterval = 300
    private let maxBackoff: TimeInterval = 15 * 60

    var lastError: String?

    init(store: AccountStore) {
        let notifier = Notifier()
        self.store = store
        self.notifier = notifier
        self.rotator = Rotator(store: store, notifier: notifier)
    }

    // MARK: - Lifecycle

    func start() {
        stop()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        notifier.prepare()

        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Anything cached across sleep is stale by definition.
                self?.lastPolled.removeAll()
                self?.backoffUntil.removeAll()
                self?.tick()
            }
        }

        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Whether a poll is in flight, so the panel can dim a card rather than tear it down.
    func isPolling(_ id: UUID) -> Bool { inFlight.contains(id) }

    /// Poll everything now, ignoring schedule and backoff.
    func refreshAll() {
        lastPolled.removeAll()
        backoffUntil.removeAll()
        tick()
    }

    // MARK: - Scheduling

    private func tick() {
        let now = Date()
        for account in store.accounts where account.enabled {
            guard !inFlight.contains(account.id) else { continue }
            if let until = backoffUntil[account.id], until > now { continue }

            let interval = store.isActive(account)
                ? store.settings.activePollSeconds
                : store.settings.idlePollSeconds

            if let last = lastPolled[account.id], now.timeIntervalSince(last) < interval { continue }

            // Stagger idle accounts so they do not all fire in the same second.
            Task { await poll(account) }
        }
    }

    private func poll(_ account: Account) async {
        inFlight.insert(account.id)
        defer { inFlight.remove(account.id) }

        lastPolled[account.id] = Date()
        // A skeleton is only honest when there is nothing to show yet. Replacing a live reading
        // or a visible error with one on every refresh makes the panel flicker and resize.
        if case .idle = store.state(account.id) {
            store.states[account.id] = .loading
        }

        do {
            let snapshot = try await fetch(account)
            store.states[account.id] = .ok(snapshot)
            store.cacheSnapshots()
            failureCount[account.id] = nil
            backoffUntil[account.id] = nil

            // Rotation is evaluated off the active account's reading, because that is the only
            // account whose usage can put the CLI over budget. Inactive readings matter only as
            // candidates, and the rotator reads those from the store itself.
            if store.isActive(account) {
                await rotator.evaluate(account.provider)
            }
        } catch {
            handle(error, for: account)
        }
    }

    private func fetch(_ account: Account) async throws -> UsageSnapshot {
        let provider = Providers.of(account.provider)

        if store.isActive(account) {
            return try await fetchActive(provider, account)
        }
        return try await fetchInactive(provider, account)
    }

    /// The CLI owns this account's tokens, so read whatever it has on disk right now and keep
    /// the vault copy in step. No refresh, no write: the CLI renews its own access token as it
    /// runs, and claudex must not rotate a refresh token it cannot hand back.
    private func fetchActive(_ provider: Provider, _ account: Account) async throws -> UsageSnapshot {
        guard let live = try provider.readCurrentCLICredentials() else {
            throw ClaudexError.notSignedIn(account.provider)
        }

        if try store.credentials(for: account) != live {
            try store.storeCredentials(live, for: account)
        }

        do {
            return try await provider.fetchUsage(live)
        } catch let error as ClaudexError where error.isUnauthorized {
            throw ClaudexError.unsupportedAccount(
                "\(account.provider.displayName) token has expired. Run the CLI once to renew it."
            )
        }
    }

    /// claudex owns inactive accounts outright, so refreshing them touches nothing else.
    private func fetchInactive(_ provider: Provider, _ account: Account) async throws -> UsageSnapshot {
        guard var credentials = try store.credentials(for: account) else {
            throw ClaudexError.unsupportedAccount("No stored credentials for \(account.label)")
        }

        if provider.needsRefresh(credentials, leeway: refreshLeeway) {
            credentials = try await refreshAndStore(provider, credentials, account)
        }

        do {
            return try await provider.fetchUsage(credentials)
        } catch let error as ClaudexError where error.isUnauthorized {
            // Rejected earlier than its stated expiry; refresh once and retry.
            let renewed = try await refreshAndStore(provider, credentials, account)
            return try await provider.fetchUsage(renewed)
        }
    }

    private func refreshAndStore(
        _ provider: Provider,
        _ credentials: Credentials,
        _ account: Account
    ) async throws -> Credentials {
        let renewed = try await provider.refresh(credentials)
        try store.storeCredentials(renewed, for: account)
        return renewed
    }

    private func handle(_ error: Error, for account: Account) {
        let count = (failureCount[account.id] ?? 0) + 1
        failureCount[account.id] = count

        let message = (error as? ClaudexError)?.errorDescription ?? error.localizedDescription
        store.states[account.id] = .failed(message)

        let retryable = (error as? ClaudexError)?.isRetryable ?? true
        let delay = retryable
            ? min(maxBackoff, store.settings.activePollSeconds * pow(2, Double(count)))
            : maxBackoff
        backoffUntil[account.id] = Date().addingTimeInterval(delay)
    }
}
