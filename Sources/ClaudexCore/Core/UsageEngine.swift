import AppKit
import Foundation
import Observation

/// Reads `tokenmaxx status` on a timer and on wake. The command reads tokenmaxx's local
/// store, so polling it often costs no provider requests.
@MainActor
@Observable
public final class UsageEngine {
    public private(set) var accounts: [UsageAccount] = []
    public private(set) var lastError: String?
    public private(set) var isLoading = false

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

        Task { await load() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NotificationCenter.default.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Has tokenmaxx re-probe every account, then reads the result.
    public func refresh() {
        Task {
            do {
                try await Tokenmaxx.refresh()
            } catch {
                lastError = (error as? ClaudexError)?.errorDescription ?? error.localizedDescription
            }
            await load()
        }
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            accounts = try await Tokenmaxx.status()
            lastError = nil
        } catch {
            // Keep the last accounts on screen; a stale reading beats an empty panel.
            lastError = (error as? ClaudexError)?.errorDescription ?? error.localizedDescription
        }
    }
}
