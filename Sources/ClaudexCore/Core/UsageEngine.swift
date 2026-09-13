import AppKit
import Foundation
import Observation

/// Owns polling admission, failure backoff, and publishing readings into account state.
/// Credential ownership and refresh rules live behind `UsageReader.reading(for:)`.
@MainActor
@Observable
public final class UsageEngine {
    private let store: AccountStore
    private let activity: LocalUsageActivity
    private let reader: UsageReader
    let notifier: Notifier
    public let rotator: Rotator
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var isRunning = false
    private var scheduler = UsagePollScheduler()
    private var failureCount: [UUID: Int] = [:]
    private var inFlight: Set<UUID> = []

    private let maxBackoff: TimeInterval = 15 * 60

    public var lastError: String?

    public init(
        store: AccountStore,
        activity: LocalUsageActivity,
        reader: UsageReader,
        notifier: Notifier,
        rotator: Rotator
    ) {
        self.store = store
        self.activity = activity
        self.reader = reader
        self.notifier = notifier
        self.rotator = rotator
    }

    // MARK: - Lifecycle

    public func start() {
        stop()
        isRunning = true
        let now = Date()
        scheduler.start(accounts: pollCandidates, activity: activityDates, now: now)
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        notifier.prepare()

        wakeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Wake checks new activity but keeps request floors and provider backoff intact.
                self?.tick()
            }
        }

        tick()
    }

    public func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NotificationCenter.default.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Whether a poll is in flight, so the panel can dim a card rather than tear it down.
    public func isPolling(_ id: UUID) -> Bool { inFlight.contains(id) }

    /// Request fresh readings. Admission still respects each account's hard floor and backoff.
    public func refreshAll() {
        scheduler.requestRefresh(store.accounts.filter(\.enabled).map(\.id))
        tick()
    }

    // MARK: - Scheduling

    private func tick() {
        guard isRunning else { return }
        let now = Date()
        let candidates = pollCandidates
        scheduler.reconcile(accounts: candidates, activity: activityDates, now: now)
        guard inFlight.isEmpty,
              let candidate = scheduler.nextDueAccount(from: candidates, now: now),
              let account = store.account(candidate.id)
        else { return }

        scheduler.didStart(candidate, at: now)
        inFlight.insert(account.id)
        Task { await poll(account, candidate: candidate) }
    }

    private func poll(_ account: Account, candidate: UsagePollCandidate) async {
        defer {
            inFlight.remove(account.id)
            tick()
        }
        // A skeleton is only honest when there is nothing to show yet. Replacing a live reading
        // or a visible error with one on every refresh makes the panel flicker and resize.
        if case .idle = store.state(account.id) {
            store.states[account.id] = .loading
        }

        do {
            let snapshot = try await reader.reading(for: account)
            store.states[account.id] = .ok(snapshot)
            store.cacheSnapshots()
            failureCount[account.id] = nil
            scheduler.didSucceed(candidate)

            // Rotation is evaluated off the active account's reading, because that is the only
            // account whose usage can put the CLI over budget. Inactive readings matter only as
            // candidates, and the rotator reads those from the store itself.
            if store.isActive(account) {
                await rotator.evaluate(account.provider)
            }
        } catch {
            handle(error, for: account, candidate: candidate)
        }
    }

    private var activityDates: [ProviderKind: Date] {
        Dictionary(uniqueKeysWithValues: ProviderKind.allCases.compactMap { provider in
            activity.latestModificationDate(for: provider).map { (provider, $0) }
        })
    }

    private var pollCandidates: [UsagePollCandidate] {
        store.accounts.filter(\.enabled).map { account in
            let active = store.isActive(account)
            return UsagePollCandidate(
                id: account.id,
                provider: account.provider,
                isActive: active,
                order: account.order,
                configuredInterval: active
                    ? store.settings.activePollSeconds
                    : store.settings.idlePollSeconds
            )
        }
    }

    private func handle(_ error: Error, for account: Account, candidate: UsagePollCandidate) {
        let count = (failureCount[account.id] ?? 0) + 1
        failureCount[account.id] = count
        let message = (error as? ClaudexError)?.errorDescription ?? error.localizedDescription
        lastError = message
        store.states[account.id] = UsageFailurePolicy.state(after: error, current: store.state(account.id))

        let retryable = (error as? ClaudexError)?.isRetryable ?? true
        let base = max(UsagePollScheduler.minimumInterval, candidate.configuredInterval)
        let delay = retryable
            ? min(maxBackoff, base * pow(2, Double(count)))
            : maxBackoff
        scheduler.didFail(candidate, retryAt: Date().addingTimeInterval(delay))
    }
}
