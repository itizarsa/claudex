import AppKit
import ClaudexCore
import Observation

/// Shared state and intents for both popover and menu-bar icon.
@MainActor
@Observable
final class PanelState {
    let engine: UsageEngine
    var showingSettings = false

    init(engine: UsageEngine) {
        self.engine = engine
    }

    var notice: String? { engine.lastError }

    /// The active account first, because it is the reading a person opens the panel for.
    var accounts: [UsageAccount] {
        engine.accounts.sorted { $0.isActive && !$1.isActive }
    }

    func refresh() { engine.refresh() }
    func switchTo(_ account: UsageAccount) { engine.switchTo(account) }
    func toggleSettings() { showingSettings.toggle() }
    func closeSettings() { showingSettings = false }
    func quit() { NSApplication.shared.terminate(nil) }
}
