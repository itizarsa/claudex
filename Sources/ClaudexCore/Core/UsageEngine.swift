import AppKit
import Foundation
import Observation

/// Reads CLIProxyAPI's accounts on a timer and on wake. The hub answers from the rate-limit
/// headers it already saw, so polling it often costs no provider requests.
@MainActor
@Observable
public final class UsageEngine {
    public private(set) var accounts: [UsageAccount] = []
    public private(set) var lastError: String?
    public private(set) var isLoading = false
    /// Set when a load is asked for mid-load, so a refresh's result isn't lost to an older read.
    private var reloadPending = false
    /// Likewise for a probe, so a refresh asked for mid-load still reaches Anthropic.
    private var probePending = false

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let interval: TimeInterval = 60

    /// Accounts can be seeded so a render probe can draw without starting the timer.
    public init(accounts: [UsageAccount] = []) {
        self.accounts = accounts
    }

    public func start() {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.load() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        wakeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.load() }
        }

        // Idle accounts have no passive reading until something is asked of Anthropic.
        refresh()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NotificationCenter.default.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Asks Anthropic for every account's usage through the hub.
    public func refresh() {
        Task { await load(probe: true) }
    }

    public func load(probe: Bool = false) async {
        probePending = probePending || probe
        guard !isLoading else { reloadPending = true; return }
        isLoading = true
        defer { isLoading = false }
        repeat {
            reloadPending = false
            let probe = probePending
            probePending = false
            do {
                merge(try await CLIProxy.status(probe: probe))
                lastError = nil
            } catch {
                // Keep the last accounts on screen; a stale reading beats an empty panel.
                lastError = (error as? ClaudexError)?.errorDescription ?? error.localizedDescription
            }
        } while reloadPending
    }

    /// A probed reading outlives the passive reads that follow it until the hub sees newer
    /// headers for that account.
    private func merge(_ fresh: [UsageAccount]) {
        let previous = Dictionary(accounts.map { ($0.id, $0.snapshot) }, uniquingKeysWith: { a, _ in a })
        accounts = fresh.map { account in
            var account = account
            if let kept = previous[account.id] ?? nil,
               kept.fetchedAt > account.snapshot?.fetchedAt ?? .distantPast {
                account.snapshot = kept
            }
            return account
        }
    }
}
