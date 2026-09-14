import Foundation

public enum LimitWindow: String, Sendable {
    case fiveHour
    case weekly

    public var displayName: String {
        switch self {
        case .fiveHour: return "5-hour"
        case .weekly: return "weekly"
        }
    }
}

public enum RotationOutcome: Equatable, Sendable {
    case stay
    case switchTo(UUID)
    case blocked(LimitWindow)
}

public struct RotationCandidate: Equatable, Sendable {
    public let account: Account
    public let snapshot: UsageSnapshot

    public init(account: Account, snapshot: UsageSnapshot) {
        self.account = account
        self.snapshot = snapshot
    }
}

/// One provider's active reading and every enabled alternative with an exact reading. Gathering
/// lives here so the app rotator and headless diagnostics evaluate identical input.
public struct Fleet: Equatable, Sendable {
    public let active: RotationCandidate
    public let candidates: [RotationCandidate]

    public init(active: RotationCandidate, candidates: [RotationCandidate]) {
        self.active = active
        self.candidates = candidates
    }
}

extension AccountStore {
    public func fleet(for kind: ProviderKind) -> Fleet? {
        guard let activeAccount = activeAccount(for: kind),
              let activeSnapshot = state(activeAccount.id).snapshot
        else { return nil }

        let candidates = accounts(for: kind)
            .filter { $0.enabled && $0.id != activeAccount.id }
            .compactMap { account in
                state(account.id).snapshot.map { RotationCandidate(account: account, snapshot: $0) }
            }
        return Fleet(
            active: RotationCandidate(account: activeAccount, snapshot: activeSnapshot),
            candidates: candidates
        )
    }
}

/// Pure rotation rule. Cooldown is explicit input rather than hidden state, and `Fleet` keeps
/// candidate gathering out of every caller.
public enum Rotation {
    public static let freshness: TimeInterval = 600
    public static let cooldown: TimeInterval = 60

    public static func exceeded(
        _ snapshot: UsageSnapshot,
        _ thresholds: ProviderThresholds
    ) -> LimitWindow? {
        if let percent = snapshot.fiveHour.percent, percent >= thresholds.fiveHour { return .fiveHour }
        if let percent = snapshot.weekly.percent, percent >= thresholds.weekly { return .weekly }
        return nil
    }

    public static func hasHeadroom(
        _ snapshot: UsageSnapshot,
        _ thresholds: ProviderThresholds
    ) -> Bool {
        guard let fiveHour = snapshot.fiveHour.percent, let weekly = snapshot.weekly.percent else {
            return false
        }
        return fiveHour < thresholds.fiveHour && weekly < thresholds.weekly
    }

    public static func decide(
        fleet: Fleet,
        thresholds: ProviderThresholds,
        lastSwitch: Date?,
        now: Date
    ) -> RotationOutcome {
        guard let window = exceeded(fleet.active.snapshot, thresholds) else { return .stay }

        let viable = fleet.candidates.filter { candidate in
            now.timeIntervalSince(candidate.snapshot.fetchedAt) < freshness
                && hasHeadroom(candidate.snapshot, thresholds)
        }
        guard let best = viable.min(by: preferred) else { return .blocked(window) }
        if let lastSwitch, now.timeIntervalSince(lastSwitch) < cooldown { return .stay }
        return .switchTo(best.account.id)
    }

    private static func preferred(_ lhs: RotationCandidate, _ rhs: RotationCandidate) -> Bool {
        let leftFive = lhs.snapshot.fiveHour.percent ?? .infinity
        let rightFive = rhs.snapshot.fiveHour.percent ?? .infinity
        if leftFive != rightFive { return leftFive < rightFive }

        let leftWeek = lhs.snapshot.weekly.percent ?? .infinity
        let rightWeek = rhs.snapshot.weekly.percent ?? .infinity
        if leftWeek != rightWeek { return leftWeek < rightWeek }
        return lhs.account.order < rhs.account.order
    }
}

/// Holds execution-only state around the pure rule: switch times, notification dedupe, and one
/// in-flight evaluation per provider.
@MainActor
public final class Rotator {
    private let store: AccountStore
    private let notifier: Notifier
    private let selector: any AccountSelecting
    private var lastSwitch: [ProviderKind: Date] = [:]
    private var announcedBlock: [ProviderKind: String] = [:]
    private var evaluating: Set<ProviderKind> = []

    public init(store: AccountStore, notifier: Notifier, selector: any AccountSelecting) {
        self.store = store
        self.notifier = notifier
        self.selector = selector
    }

    public func noteManualSwitch(_ kind: ProviderKind) {
        lastSwitch[kind] = Date()
        announcedBlock[kind] = nil
    }

    public func evaluate(_ kind: ProviderKind) async {
        guard store.settings.autoSwitchEnabled, !evaluating.contains(kind) else { return }
        guard let fleet = store.fleet(for: kind) else { return }

        evaluating.insert(kind)
        defer { evaluating.remove(kind) }

        let thresholds = store.settings.thresholds(for: kind)
        let now = Date()
        switch Rotation.decide(
            fleet: fleet,
            thresholds: thresholds,
            lastSwitch: lastSwitch[kind],
            now: now
        ) {
        case .stay:
            if Rotation.exceeded(fleet.active.snapshot, thresholds) == nil {
                announcedBlock[kind] = nil
            }

        case .blocked(let window):
            announceBlocked(kind, window: window, snapshot: fleet.active.snapshot)

        case .switchTo(let id):
            guard let target = store.account(id) else { return }
            await perform(target, from: fleet.active.account)
        }
    }

    private func perform(_ target: Account, from outgoing: Account) async {
        do {
            guard try await selector.select(target) else { return }
            lastSwitch[target.provider] = Date()
            announcedBlock[target.provider] = nil
            notify(
                title: "Switched \(target.provider.displayName) to \(target.label)",
                body: "\(outgoing.label) passed its limit. Routed sessions use \(target.label) on their next request."
            )
        } catch {
            notify(
                title: "\(target.provider.displayName) switch failed",
                body: ErrorPresenter.message(error)
            )
        }
    }

    private func announceBlocked(_ kind: ProviderKind, window: LimitWindow, snapshot: UsageSnapshot) {
        let resetsAt = window == .fiveHour ? snapshot.fiveHour.resetsAt : snapshot.weekly.resetsAt
        let key = "\(window.rawValue)@\(resetsAt?.timeIntervalSince1970 ?? 0)"
        guard announcedBlock[kind] != key else { return }
        announcedBlock[kind] = key

        let reset = Formatting.resetLine(resetsAt)
        notify(
            title: "Every \(kind.displayName) account is over its \(window.displayName) limit",
            body: reset.isEmpty
                ? "No account has headroom to switch to."
                : "No account has headroom to switch to. \(reset)."
        )
    }

    private func notify(title: String, body: String) {
        guard store.settings.notificationsEnabled else { return }
        notifier.post(title: title, body: body)
    }
}
