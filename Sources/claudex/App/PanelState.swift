import AppKit
import ClaudexCore
import Observation

/// Shared state and intents for both popover and menu-bar icon. Views draw values and forward
/// gestures; switching, sign-in, notices, and busy-state transitions live here once.
@MainActor
@Observable
final class PanelState {
    struct StatusEntry {
        let kind: ProviderKind
        let account: Account?
        let snapshot: UsageSnapshot?
    }

    private let store: AccountStore
    let engine: UsageEngine
    private let switcher: any AccountSwitching
    private let login: any AccountSigningIn

    var notice: String?
    var switchingAccount: UUID?
    var showingSettings = false
    var signingIn: ProviderKind?

    init(
        store: AccountStore,
        engine: UsageEngine,
        switcher: any AccountSwitching,
        login: any AccountSigningIn
    ) {
        self.store = store
        self.engine = engine
        self.switcher = switcher
        self.login = login
    }

    var settings: ClaudexCore.Settings { store.settings }
    var isBusy: Bool { signingIn != nil }

    func accounts(for kind: ProviderKind) -> [Account] {
        store.accounts(for: kind).sorted { lhs, rhs in
            let left = store.isActive(lhs)
            let right = store.isActive(rhs)
            if left != right { return left }
            return lhs.order < rhs.order
        }
    }

    func accountState(_ account: Account) -> AccountState { store.state(account.id) }
    func isActive(_ account: Account) -> Bool { store.isActive(account) }
    func isPolling(_ account: Account) -> Bool { engine.isPolling(account.id) }

    var statusEntries: [StatusEntry] {
        ProviderKind.allCases.compactMap { kind in
            let accounts = store.accounts(for: kind)
            guard !accounts.isEmpty else { return nil }
            let account = store.activeAccount(for: kind) ?? accounts.first
            return StatusEntry(
                kind: kind,
                account: account,
                snapshot: account.flatMap { store.state($0.id).snapshot }
            )
        }
    }

    func setAlias(_ raw: String, for account: Account) { store.setAlias(raw, for: account) }
    func remove(_ account: Account) { store.remove(account) }

    func refresh() {
        notice = nil
        engine.refreshAll()
    }

    func toggleSettings() {
        notice = nil
        showingSettings.toggle()
    }

    func closeSettings() { showingSettings = false }

    func updateSetting<Value>(_ keyPath: WritableKeyPath<ClaudexCore.Settings, Value>, _ value: Value) {
        store.settings[keyPath: keyPath] = value
        store.settings.save()
    }

    func updateThreshold(
        _ kind: ProviderKind,
        _ keyPath: WritableKeyPath<ProviderThresholds, Double>,
        _ value: Double
    ) {
        var thresholds = store.settings.thresholds(for: kind)
        thresholds[keyPath: keyPath] = value
        store.settings.thresholds[kind] = thresholds
    }

    func saveSettings() { store.settings.save() }

    func activate(_ account: Account) {
        guard !store.isActive(account), switchingAccount == nil else { return }
        switchingAccount = account.id
        notice = nil
        Task {
            defer { switchingAccount = nil }
            do {
                _ = try await switcher.activate(account)
                engine.rotator.noteManualSwitch(account.provider)
                engine.refreshAll()
            } catch {
                notice = ErrorPresenter.message(error)
            }
        }
    }

    func signIn(_ kind: ProviderKind) {
        guard !isBusy else { return }
        signingIn = kind
        notice = "Finish the sign-in in your browser. Claudex is waiting for it."
        Task {
            defer { signingIn = nil }
            do {
                let result = try await login.run(kind)
                Log.write("panel: sign-in returned \(result.account.label), already known \(result.wasAlreadyKnown)")
                notice = result.wasAlreadyKnown
                    ? "\(result.account.label) was already tracked. Its credentials are up to date."
                    : "Added \(result.account.label). It is not active — switch to it when you want it."
                engine.refreshAll()
            } catch {
                Log.write("panel: sign-in failed — \((error as? ClaudexError)?.errorDescription ?? error.localizedDescription)")
                notice = ErrorPresenter.message(error)
            }
        }
    }

    func quit() { NSApplication.shared.terminate(nil) }
}
