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
        await pollOnce(into: AccountStore())
    }

    @MainActor
    static func pollOnce(into store: AccountStore) async {
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

    /// Dry run of the rotation rule: polls everything, then prints what the rotator would do
    /// with those readings and why. Never switches, so the thresholds can be tuned against live
    /// numbers without the tuning itself moving an account.
    @MainActor
    static func rotationPlan() async {
        let store = AccountStore()
        guard !store.accounts.isEmpty else {
            print("no accounts; run --import first")
            return
        }
        await pollOnce(into: store)

        let now = Date()
        for kind in ProviderKind.allCases where !store.accounts(for: kind).isEmpty {
            let thresholds = store.settings.thresholds(for: kind)
            print("== \(kind.displayName) == thresholds 5h \(Int(thresholds.fiveHour))% / week \(Int(thresholds.weekly))%")

            guard let active = store.activeAccount(for: kind) else {
                print("  no active account")
                continue
            }
            guard let snapshot = store.state(active.id).snapshot else {
                print("  \(active.label) has no usable reading")
                continue
            }
            // A poll that failed above leaves the cached reading in place, and a decision made
            // on a stale number is worth knowing about before the thresholds are blamed.
            let age = now.timeIntervalSince(snapshot.fetchedAt)
            if age > 60 {
                print("  note: \(active.label)'s reading is \(Int(age / 60))m old")
            }

            let candidates = store.accounts(for: kind)
                .filter { $0.enabled && $0.id != active.id }
                .compactMap { account in
                    store.state(account.id).snapshot.map {
                        RotationCandidate(account: account, snapshot: $0)
                    }
                }

            switch Rotator.decide(active: snapshot, candidates: candidates, thresholds: thresholds, now: now) {
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
    static func login(_ name: String) async {
        guard let kind = ProviderKind(rawValue: name.lowercased()) else {
            print("unknown provider \(name); use claude or codex")
            return
        }
        let store = AccountStore()
        print("opening the browser for the \(kind.displayName) sign-in…")
        do {
            let result = try await SandboxedLogin.run(kind, into: store)
            let status = result.wasAlreadyKnown ? "updated" : "added"
            print("\(status) \(result.account.label) (\(result.account.identity.email), \(result.account.identity.plan))")
            print("  not active; run --switch \(result.account.label) to sign the CLI into it")
        } catch {
            print("sign-in failed: \((error as? ClaudexError)?.errorDescription ?? error.localizedDescription)")
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

import AppKit

extension Probe {
    /// Writes the menu-bar image to a PNG at 2x so its geometry can be measured against a
    /// screenshot of the app it is modelled on. Each argument takes a comma-separated list, one
    /// element per ring, so the grouped layout can be checked too. Diagnostics only; nothing in
    /// the app calls it.
    /// Writes the app icon at 1024 so `make icon` can hand it to `iconutil`. Drawn by the same
    /// binary that draws the ring, so the two cannot drift apart.
    @MainActor
    static func renderAppIcon(path: String) {
        do {
            try AppIcon.write(to: path)
            print("wrote \(path)")
        } catch {
            print("app icon failed: \((error as? ClaudexError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    @MainActor
    static func renderIcon(path: String, alias: String, percent: String, elapsed: String) {
        let aliases = alias.split(separator: ",").map(String.init)
        let percents = percent.split(separator: ",").map { Double($0) }
        let elapseds = elapsed.split(separator: ",").map { Double($0) ?? 0 }

        let entries = aliases.enumerated().map { index, alias -> MenuBarIcon.Entry in
            let spent = index < elapseds.count ? elapseds[index] : 0
            let window = UsageWindow(
                percent: index < percents.count ? percents[index] : nil,
                resetsAt: Date().addingTimeInterval(5 * 3600 * (1 - spent)),
                windowSeconds: 5 * 3600
            )
            return MenuBarIcon.Entry(alias: alias, fiveHour: window)
        }
        let image = MenuBarIcon.rings(entries)

        let pixelWidth = Int(image.size.width.rounded()) * 2
        let pixelHeight = Int(image.size.height.rounded()) * 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = image.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) at \(pixelWidth)x\(pixelHeight)")
    }
}
