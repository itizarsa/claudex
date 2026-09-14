import Foundation

public enum Probe {
    /// Exercises the read path against whatever the CLIs are signed into and prints what
    /// claudex parsed. Writes nothing.
    public static func run(providers: ProviderRegistry) async {
        for kind in ProviderKind.allCases {
            print("== \(kind.displayName) ==")

            do {
                let provider = try providers.provider(for: kind)
                guard let credentials = try provider.currentCLICredentials() else {
                    print("  not signed in")
                    continue
                }
                print("  refresh fingerprint: \(credentials.refreshFingerprint)")
                print("  needs refresh: \(provider.needsRefresh(credentials, leeway: 300))")

                let identity = try await provider.identity(credentials)
                print("  identity: \(identity.email) | \(identity.plan) | org \(identity.organization ?? "-") | id \(identity.remoteID)")

                let usage = try await provider.usage(credentials)
                print("  5h:   \(usage.fiveHour.percentText) \(usage.fiveHour.resetText)")
                print("  week: \(usage.weekly.percentText) \(usage.weekly.resetText)")
            } catch {
                let message = (error as? ClaudexError)?.errorDescription ?? error.localizedDescription
                print("  FAILED: \(message)")
            }
        }
    }

    /// Round-trips a throwaway item through claudex's own Keychain service. Confirms the
    /// vault works without an authorisation prompt, separately from any CLI-owned item.
    public static func vaultSelfTest(store: any CredentialStore) {
        let id = UUID()
        let sample = Credentials.codex(CodexCredentials(
            idToken: "test", accessToken: "test", refreshToken: "test", accountID: "test", lastRefresh: nil
        ))
        do {
            try store.store(sample, for: id)
            let loaded = try store.load(id)
            try store.delete(id)
            print("vault: \(loaded == sample ? "ok" : "round-trip mismatch")")
        } catch {
            print("vault: FAILED \((error as? ClaudexError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    /// One poll cycle against the stored accounts, printing each step. Unlike `--probe` this
    /// goes through claudex's own vault, so it also proves Keychain access works for the
    /// binary it is run from.
    @MainActor
    public static func pollOnce(store: AccountStore, reader: UsageReader) async {
        guard !store.accounts.isEmpty else {
            print("no accounts; run --import first")
            return
        }
        for account in store.accounts {
            let active = store.isActive(account)
            print("\(account.provider.rawValue) / \(account.label)\(active ? " (active)" : "")")
            do {
                let usage = try await reader.reading(for: account)
                print("  5h \(usage.fiveHour.percentText)  week \(usage.weekly.percentText)")
                store.states[account.id] = .ok(usage)
            } catch {
                print("  FAILED: \((error as? ClaudexError)?.errorDescription ?? error.localizedDescription)")
            }
        }
        store.cacheSnapshots()
    }

    /// Headless proxy-account selection by label.
    @MainActor
    public static func switchTo(
        _ label: String,
        store: AccountStore,
        selector: any AccountSelecting
    ) async {
        guard let account = store.accounts.first(where: { $0.label == label }) else {
            print("no account labelled \(label)")
            return
        }
        do {
            guard try await selector.select(account) else {
                print("\(account.label) is already active")
                return
            }
            print("selected \(account.provider.rawValue) account \(account.label) for proxy routing")
        } catch {
            print("switch failed: \((error as? ClaudexError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    /// Dry run of the rotation rule: polls everything, then prints what the rotator would do
    /// with those readings and why. Never switches, so the thresholds can be tuned against live
    /// numbers without the tuning itself moving an account.
    @MainActor
    public static func rotationPlan(store: AccountStore, reader: UsageReader) async {
        guard !store.accounts.isEmpty else {
            print("no accounts; run --import first")
            return
        }
        await pollOnce(store: store, reader: reader)

        let now = Date()
        for kind in ProviderKind.allCases where !store.accounts(for: kind).isEmpty {
            let thresholds = store.settings.thresholds(for: kind)
            print("== \(kind.displayName) == thresholds 5h \(Int(thresholds.fiveHour))% / week \(Int(thresholds.weekly))%")

            guard let fleet = store.fleet(for: kind) else {
                print("  no active account with a usable reading")
                continue
            }
            let active = fleet.active.account
            let snapshot = fleet.active.snapshot
            // A poll that failed above leaves the cached reading in place, and a decision made
            // on a stale number is worth knowing about before the thresholds are blamed.
            let age = now.timeIntervalSince(snapshot.fetchedAt)
            if age > 60 {
                print("  note: \(active.label)'s reading is \(Int(age / 60))m old")
            }

            switch Rotation.decide(fleet: fleet, thresholds: thresholds, lastSwitch: nil, now: now) {
            case .stay:
                print("  stay on \(active.label) (5h \(snapshot.fiveHour.percentText), week \(snapshot.weekly.percentText))")
            case .blocked(let window):
                print("  \(active.label) is over its \(window.displayName) limit, and no candidate has headroom")
            case .switchTo(let id):
                let target = store.account(id)?.label ?? id.uuidString
                print("  would switch \(active.label) -> \(target)")
            }
            if !store.settings.autoSwitchEnabled {
                print("  (automatic switching is off, so nothing would happen)")
            }
        }
    }

    /// Headless equivalent of the popover's "Sign in". Runs the CLI's own login against a
    /// throwaway directory and adopts whatever it writes there, leaving the account the CLI is
    /// signed into alone.
    @MainActor
    public static func login(_ name: String, login: any AccountSigningIn) async {
        guard let kind = ProviderKind(rawValue: name.lowercased()) else {
            print("unknown provider \(name); use claude or codex")
            return
        }
        print("opening the browser for the \(kind.displayName) sign-in…")
        do {
            let result = try await login.run(kind)
            let status = result.wasAlreadyKnown ? "updated" : "added"
            print("\(status) \(result.account.label) (\(result.account.identity.email), \(result.account.identity.plan))")
            print("  not active; run --switch \(result.account.label) to sign the CLI into it")
        } catch {
            print("sign-in failed: \((error as? ClaudexError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    @MainActor
    public static func list(store: AccountStore) {
        guard !store.accounts.isEmpty else {
            print("no accounts")
            return
        }
        for kind in ProviderKind.allCases {
            for account in store.accounts(for: kind) {
                let marker = store.isActive(account) ? "*" : " "
                let snapshot = store.state(account.id).snapshot
                let fiveHour = snapshot?.fiveHour.percentText ?? "—"
                let weekly = snapshot?.weekly.percentText ?? "—"
                print("\(marker) \(kind.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(account.label)  5h \(fiveHour)  week \(weekly)  [\(account.identity.plan)]")
            }
        }
    }
}
