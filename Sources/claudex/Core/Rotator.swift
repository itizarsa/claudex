import Foundation

/// Which limit window put an account over budget. Carried out of the decision so the
/// notification can name it, and so "everything is over" is announced once per window rather
/// than once per poll.
enum LimitWindow: String, Sendable {
    case fiveHour
    case weekly

    var displayName: String {
        switch self {
        case .fiveHour: return "5-hour"
        case .weekly: return "weekly"
        }
    }
}

enum RotationOutcome: Equatable, Sendable {
    /// The active account is within budget, or there is nothing to compare it against.
    case stay
    case switchTo(UUID)
    /// Over budget with nowhere to go: every other account is over its own limit, stale, or
    /// reporting an unknown figure.
    case blocked(LimitWindow)
}

struct RotationCandidate: Equatable, Sendable {
    let account: Account
    let snapshot: UsageSnapshot
}

/// Threshold evaluation, cooldown and the switch it drives.
///
/// `decide` is pure and takes its clock as an argument, so the rule can be reasoned about
/// without a store, a network or a timer behind it. The class around it holds only the two
/// pieces of state the rule cannot carry: when this provider last switched, and which
/// "everything is over" message has already been sent.
@MainActor
final class Rotator {
    /// A snapshot older than this says nothing about the account's current headroom, so it
    /// disqualifies the account as a target rather than being trusted.
    static let freshness: TimeInterval = 600
    /// Two accounts sitting either side of the line would otherwise trade places every poll.
    static let cooldown: TimeInterval = 60

    private let store: AccountStore
    private let notifier: Notifier
    private var lastSwitch: [ProviderKind: Date] = [:]
    private var announcedBlock: [ProviderKind: String] = [:]
    private var evaluating: Set<ProviderKind> = []

    init(store: AccountStore, notifier: Notifier) {
        self.store = store
        self.notifier = notifier
    }

    // MARK: - The rule

    /// True when a window is at or over its threshold. An unknown percentage is never over
    /// budget: the API not reporting a window is not evidence that it is full.
    static func exceeded(_ snapshot: UsageSnapshot, _ thresholds: ProviderThresholds) -> LimitWindow? {
        if let percent = snapshot.fiveHour.percent, percent >= thresholds.fiveHour { return .fiveHour }
        if let percent = snapshot.weekly.percent, percent >= thresholds.weekly { return .weekly }
        return nil
    }

    /// A target must be demonstrably under both thresholds. An unknown window disqualifies it,
    /// because switching to an account whose usage cannot be read is a guess, and the one
    /// failure mode worth avoiding is treating a missing figure as headroom.
    static func hasHeadroom(_ snapshot: UsageSnapshot, _ thresholds: ProviderThresholds) -> Bool {
        guard let fiveHour = snapshot.fiveHour.percent, let weekly = snapshot.weekly.percent else {
            return false
        }
        return fiveHour < thresholds.fiveHour && weekly < thresholds.weekly
    }

    static func decide(
        active: UsageSnapshot,
        candidates: [RotationCandidate],
        thresholds: ProviderThresholds,
        now: Date
    ) -> RotationOutcome {
        guard let window = exceeded(active, thresholds) else { return .stay }

        let viable = candidates.filter { candidate in
            now.timeIntervalSince(candidate.snapshot.fetchedAt) < freshness
                && hasHeadroom(candidate.snapshot, thresholds)
        }

        guard let best = viable.min(by: preferred) else { return .blocked(window) }
        return .switchTo(best.account.id)
    }

    /// Lowest 5-hour first, then lowest weekly, then the user's own ordering.
    private static func preferred(_ lhs: RotationCandidate, _ rhs: RotationCandidate) -> Bool {
        let leftFive = lhs.snapshot.fiveHour.percent ?? .infinity
        let rightFive = rhs.snapshot.fiveHour.percent ?? .infinity
        if leftFive != rightFive { return leftFive < rightFive }

        let leftWeek = lhs.snapshot.weekly.percent ?? .infinity
        let rightWeek = rhs.snapshot.weekly.percent ?? .infinity
        if leftWeek != rightWeek { return leftWeek < rightWeek }

        return lhs.account.order < rhs.account.order
    }

    // MARK: - Driving it

    /// A manual switch is always allowed, and starts the cooldown afresh so the rotator does
    /// not immediately undo a choice the user just made by hand.
    func noteManualSwitch(_ kind: ProviderKind) {
        lastSwitch[kind] = Date()
        announcedBlock[kind] = nil
    }

    /// Called after every successful poll of a provider's active account.
    func evaluate(_ kind: ProviderKind) async {
        guard store.settings.autoSwitchEnabled, !evaluating.contains(kind) else { return }
        guard let active = store.activeAccount(for: kind),
              let snapshot = store.state(active.id).snapshot
        else { return }

        evaluating.insert(kind)
        defer { evaluating.remove(kind) }

        let thresholds = store.settings.thresholds(for: kind)
        let now = Date()
        let candidates = store.accounts(for: kind)
            .filter { $0.enabled && $0.id != active.id }
            .compactMap { account in
                store.state(account.id).snapshot.map {
                    RotationCandidate(account: account, snapshot: $0)
                }
            }

        switch Rotator.decide(
            active: snapshot,
            candidates: candidates,
            thresholds: thresholds,
            now: now
        ) {
        case .stay:
            // Back under budget: the next exhaustion deserves a fresh notification.
            announcedBlock[kind] = nil

        case .blocked(let window):
            announceBlocked(kind, window: window, snapshot: snapshot)

        case .switchTo(let id):
            if let last = lastSwitch[kind], now.timeIntervalSince(last) < Rotator.cooldown { return }
            guard let target = store.account(id) else { return }
            await perform(target, from: active)
        }
    }

    private func perform(_ target: Account, from outgoing: Account) async {
        do {
            guard try await Switcher.activate(target, in: store) else { return }
            lastSwitch[target.provider] = Date()
            announcedBlock[target.provider] = nil
            notify(
                title: "Switched \(target.provider.displayName) to \(target.label)",
                body: "\(outgoing.label) passed its limit. Sessions already running keep using it — "
                    + "the change applies to the next one you start."
            )
        } catch {
            notify(
                title: "\(target.provider.displayName) switch failed",
                body: ErrorPresenter.message(error)
            )
        }
    }

    /// One notification per limit window, not one per poll. The window's own reset time is what
    /// makes the key: a new five-hour window is a new situation, the same one is not.
    private func announceBlocked(_ kind: ProviderKind, window: LimitWindow, snapshot: UsageSnapshot) {
        let resetsAt = window == .fiveHour ? snapshot.fiveHour.resetsAt : snapshot.weekly.resetsAt
        let key = "\(window.rawValue)@\(resetsAt?.timeIntervalSince1970 ?? 0)"
        guard announcedBlock[kind] != key else { return }
        announcedBlock[kind] = key

        let reset = Formatting.resetLine(resetsAt)
        notify(
            title: "Every \(kind.displayName) account is over its \(window.displayName) limit",
            body: reset.isEmpty ? "No account has headroom to switch to." : "No account has headroom to switch to. \(reset)."
        )
    }

    private func notify(title: String, body: String) {
        guard store.settings.notificationsEnabled else { return }
        notifier.post(title: title, body: body)
    }
}
