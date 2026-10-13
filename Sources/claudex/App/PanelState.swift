import AppKit
import ClaudexCore
import Observation

/// Shared state and intents for both popover and menu-bar icon.
@MainActor
@Observable
final class PanelState {
    struct StatusEntry {
        let kind: ProviderKind
        let account: UsageAccount?
    }

    let engine: UsageEngine
    var showingSettings = false

    init(engine: UsageEngine) {
        self.engine = engine
    }

    var notice: String? { engine.lastError }

    /// The active account first, because it is the reading a person opens the panel for.
    func accounts(for kind: ProviderKind) -> [UsageAccount] {
        engine.accounts
            .filter { $0.provider == kind }
            .sorted { $0.isActive && !$1.isActive }
    }

    var statusEntries: [StatusEntry] {
        ProviderKind.allCases.compactMap { kind in
            let accounts = accounts(for: kind)
            guard !accounts.isEmpty else { return nil }
            return StatusEntry(kind: kind, account: accounts.first)
        }
    }

    func refresh() { engine.refresh() }
    func switchTo(_ account: UsageAccount) { engine.switchTo(account) }
    func toggleSettings() { showingSettings.toggle() }
    func closeSettings() { showingSettings = false }
    func quit() { NSApplication.shared.terminate(nil) }
}
