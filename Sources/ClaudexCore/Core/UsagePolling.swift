import Foundation

/// File activity says a CLI probably consumed usage. File contents are deliberately untouched:
/// JSONL cannot state exact plan utilisation and may contain private conversation text.
public struct LocalUsageActivity: Sendable {
    private let roots: [ProviderKind: URL]

    public init() {
        self.init(roots: [
            .claude: Paths.claudeProjects,
            .codex: Paths.codexSessions,
        ])
    }

    init(roots: [ProviderKind: URL]) {
        self.roots = roots
    }

    func latestModificationDate(for provider: ProviderKind) -> Date? {
        guard let root = roots[provider],
              let files = FileManager.default.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              )
        else { return nil }

        var latest: Date?
        for case let file as URL in files where file.pathExtension.lowercased() == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { continue }
            if latest.map({ modified > $0 }) ?? true { latest = modified }
        }
        return latest
    }
}

struct UsagePollCandidate: Equatable, Sendable {
    let id: UUID
    let provider: ProviderKind
    let isActive: Bool
    let order: Int
    let configuredInterval: TimeInterval

    var effectiveInterval: TimeInterval {
        max(UsagePollScheduler.minimumInterval, configuredInterval)
    }
}

/// Pure scheduling state. Network ownership stays in `UsageEngine`; keeping admission here makes
/// minimum intervals, activity triggers and initial staggering testable without real accounts.
struct UsagePollScheduler {
    static let minimumInterval: TimeInterval = 5 * 60

    private var hasStarted = false
    private var initialEligibleAt: [UUID: Date] = [:]
    private var lastAttemptAt: [UUID: Date] = [:]
    private var backoffUntil: [UUID: Date] = [:]
    private var requested: Set<UUID> = []
    private var observedActivityAt: [ProviderKind: Date] = [:]
    private var providersWithPendingActivity: Set<ProviderKind> = []

    mutating func start(
        accounts: [UsagePollCandidate],
        activity: [ProviderKind: Date],
        now: Date
    ) {
        guard !hasStarted else { return }
        hasStarted = true
        observedActivityAt = activity

        let inactive = accounts
            .filter { !$0.isActive }
            .sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.id.uuidString < $1.id.uuidString
            }
        if let staggerWindow = inactive.map(\.effectiveInterval).min() {
            for (index, account) in inactive.enumerated() {
                let fraction = Double(index + 1) / Double(inactive.count + 1)
                initialEligibleAt[account.id] = now.addingTimeInterval(staggerWindow * fraction)
            }
        }
        for account in accounts where account.isActive {
            initialEligibleAt[account.id] = now
        }
    }

    mutating func reconcile(
        accounts: [UsagePollCandidate],
        activity: [ProviderKind: Date],
        now: Date
    ) {
        if !hasStarted { start(accounts: accounts, activity: activity, now: now) }
        for (provider, date) in activity { observeActivity(for: provider, at: date) }

        let liveIDs = Set(accounts.map(\.id))
        initialEligibleAt = initialEligibleAt.filter { liveIDs.contains($0.key) }
        lastAttemptAt = lastAttemptAt.filter { liveIDs.contains($0.key) }
        backoffUntil = backoffUntil.filter { liveIDs.contains($0.key) }
        requested.formIntersection(liveIDs)

        for account in accounts where initialEligibleAt[account.id] == nil && lastAttemptAt[account.id] == nil {
            initialEligibleAt[account.id] = account.isActive
                ? now
                : now.addingTimeInterval(account.effectiveInterval)
        }
    }

    mutating func observeActivity(for provider: ProviderKind, at date: Date) {
        guard let previous = observedActivityAt[provider] else {
            observedActivityAt[provider] = date
            return
        }
        guard date > previous else { return }
        observedActivityAt[provider] = date
        providersWithPendingActivity.insert(provider)
    }

    mutating func requestRefresh(_ accountIDs: [UUID]) {
        requested.formUnion(accountIDs)
    }

    func nextDueAccount(from accounts: [UsagePollCandidate], now: Date) -> UsagePollCandidate? {
        accounts.compactMap { account -> (UsagePollCandidate, Date)? in
            let explicitlyRequested = requested.contains(account.id)
            let eligibility: Date

            if let last = lastAttemptAt[account.id] {
                let floor = last.addingTimeInterval(account.effectiveInterval)
                eligibility = max(floor, backoffUntil[account.id] ?? .distantPast)
                if !explicitlyRequested {
                    if account.isActive {
                        guard providersWithPendingActivity.contains(account.provider) else { return nil }
                    }
                }
            } else {
                eligibility = explicitlyRequested ? now : (initialEligibleAt[account.id] ?? now)
            }

            return eligibility <= now ? (account, eligibility) : nil
        }
        .sorted { left, right in
            let leftRequested = requested.contains(left.0.id)
            let rightRequested = requested.contains(right.0.id)
            if leftRequested != rightRequested { return leftRequested }
            if left.1 != right.1 { return left.1 < right.1 }
            if left.0.isActive != right.0.isActive { return left.0.isActive }
            return left.0.order < right.0.order
        }
        .first?.0
    }

    mutating func didStart(_ account: UsagePollCandidate, at date: Date) {
        lastAttemptAt[account.id] = date
        initialEligibleAt[account.id] = nil
        requested.remove(account.id)
        if account.isActive { providersWithPendingActivity.remove(account.provider) }
    }

    mutating func didSucceed(_ account: UsagePollCandidate) {
        backoffUntil[account.id] = nil
    }

    mutating func didFail(_ account: UsagePollCandidate, retryAt: Date) {
        backoffUntil[account.id] = retryAt
    }
}

enum UsageFailurePolicy {
    static func state(after error: Error, current: AccountState) -> AccountState {
        let typed = error as? ClaudexError
        if (typed?.isRetryable ?? true), current.snapshot != nil { return current }
        return .failed(typed?.errorDescription ?? error.localizedDescription)
    }
}

struct RateLimitRecovery {
    private var counts: [UUID: Int] = [:]
    private var attempted: Set<UUID> = []

    mutating func shouldRefreshAfterRateLimit(for accountID: UUID) -> Bool {
        let count = (counts[accountID] ?? 0) + 1
        counts[accountID] = count
        guard count >= 2, !attempted.contains(accountID) else { return false }
        attempted.insert(accountID)
        return true
    }

    mutating func reset(_ accountID: UUID) {
        counts[accountID] = nil
        attempted.remove(accountID)
    }
}
