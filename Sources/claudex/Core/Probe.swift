import Foundation

enum Probe {
    /// Exercises the read path against whatever the CLIs are signed into and prints what
    /// claudex parsed. Writes nothing.
    static func run() async {
        for kind in ProviderKind.allCases {
            print("== \(kind.displayName) ==")
            let provider = Providers.of(kind)

            do {
                guard let credentials = try provider.readCurrentCLICredentials() else {
                    print("  not signed in")
                    continue
                }
                print("  refresh fingerprint: \(credentials.refreshFingerprint)")
                print("  needs refresh: \(provider.needsRefresh(credentials, leeway: 300))")

                let identity = try await provider.fetchIdentity(credentials)
                print("  identity: \(identity.email) | \(identity.plan) | org \(identity.organization ?? "-") | id \(identity.remoteID)")

                let usage = try await provider.fetchUsage(credentials)
                print("  5h:   \(usage.fiveHour.percentText) \(usage.fiveHour.resetText)")
                print("  week: \(usage.weekly.percentText) \(usage.weekly.resetText)")
            } catch {
                let message = (error as? ClaudexError)?.errorDescription ?? error.localizedDescription
                print("  FAILED: \(message)")
            }
        }
    }

    /// Headless equivalent of the popover's "Import current" button. Touches only claudex's
    /// own store and Keychain items, never the CLI's credentials.
    @MainActor
    static func importCurrent() async {
        let store = AccountStore()
        for kind in ProviderKind.allCases {
            do {
                let result = try await CLIImport.importCurrent(kind, into: store)
                let status = result.wasAlreadyKnown ? "updated" : "added"
                print("\(kind.displayName): \(status) \(result.account.label) (\(result.account.identity.email))")
            } catch {
                let message = (error as? ClaudexError)?.errorDescription ?? error.localizedDescription
                print("\(kind.displayName): skipped — \(message)")
            }
        }
    }

    /// Round-trips a throwaway item through claudex's own Keychain service. Confirms the
    /// vault works without an authorisation prompt, separately from any CLI-owned item.
    static func vaultSelfTest() {
        let id = UUID()
        let sample = Credentials.codex(CodexCredentials(
            idToken: "test", accessToken: "test", refreshToken: "test", accountID: "test", lastRefresh: nil
        ))
        do {
            try Vault.store(sample, for: id)
            let loaded = try Vault.load(id)
            try Vault.delete(id)
            print("vault: \(loaded == sample ? "ok" : "round-trip mismatch")")
        } catch {
            print("vault: FAILED \((error as? ClaudexError)?.errorDescription ?? error.localizedDescription)")
        }

        guard Vault.useKeychain else { return }
        // The migration path only runs for accounts stored before the Keychain became usable,
        // which no live account may still be in. Exercise it here rather than leave it to be
        // discovered by the one account that needs it.
        let migrationID = UUID()
        do {
            try FileVault.store(sample, for: migrationID)
            let loaded = try Vault.load(migrationID)
            let movedOut = try FileVault.load(migrationID) == nil
            let movedIn = try KeychainVault.load(migrationID) == sample
            try Vault.delete(migrationID)
            let verdict = loaded == sample && movedOut && movedIn
            print("vault migration: \(verdict ? "ok" : "file entry not moved to Keychain")")
        } catch {
            print("vault migration: FAILED \((error as? ClaudexError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    /// One poll cycle against the stored accounts, printing each step. Unlike `--probe` this
    /// goes through claudex's own vault, so it also proves Keychain access works for the
    /// binary it is run from.
    @MainActor
    static func pollOnce() async {
        let store = AccountStore()
        guard !store.accounts.isEmpty else {
            print("no accounts; run --import first")
            return
        }
        for account in store.accounts {
            let active = store.isActive(account)
            print("\(account.provider.rawValue) / \(account.label)\(active ? " (active)" : "")")
            do {
                let provider = Providers.of(account.provider)
                // Mirrors the engine's rule: the CLI owns the active account's tokens, so read
                // them live rather than trusting the vault copy.
                let credentials: Credentials?
                if active {
                    credentials = try provider.readCurrentCLICredentials()
                } else {
                    credentials = try store.credentials(for: account)
                }
                guard let credentials else {
                    print("  no credentials available")
                    continue
                }
                print("  source: \(active ? "CLI" : "vault"), needs refresh: \(provider.needsRefresh(credentials, leeway: 300))")
                let usage = try await provider.fetchUsage(credentials)
                print("  5h \(usage.fiveHour.percentText)  week \(usage.weekly.percentText)")
                store.states[account.id] = .ok(usage)
            } catch {
                print("  FAILED: \((error as? ClaudexError)?.errorDescription ?? error.localizedDescription)")
            }
        }
        store.cacheSnapshots()
    }

    /// Headless switch, by label. The one path that writes to a CLI's own storage, so it reports
    /// what the CLI reads back afterwards rather than only that the write returned.
    @MainActor
    static func switchTo(_ label: String) async {
        let store = AccountStore()
        guard let account = store.accounts.first(where: { $0.label == label }) else {
            print("no account labelled \(label)")
            return
        }
        do {
            guard try await Switcher.activate(account, in: store) else {
                print("\(account.label) is already active")
                return
            }
            let provider = Providers.of(account.provider)
            let live = try provider.readCurrentCLICredentials()
            let matches = live?.refreshFingerprint == (try store.credentials(for: account))?.refreshFingerprint
            print("switched \(account.provider.rawValue) to \(account.label)")
            print("  CLI reads back: \(matches ? "same credentials" : "MISMATCH")")
        } catch {
            print("switch failed: \((error as? ClaudexError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    @MainActor
    static func list() {
        let store = AccountStore()
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
