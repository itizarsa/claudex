import Foundation
import Observation

private struct PersistedAccounts: Codable {
    var accounts: [Account]
    var active: [ProviderKind: UUID]
}

@MainActor
@Observable
final class AccountStore {
    private(set) var accounts: [Account] = []
    /// The account claudex believes each CLI is currently signed into.
    private(set) var active: [ProviderKind: UUID] = [:]
    var states: [UUID: AccountState] = [:]
    var settings: Settings = .load()

    init() {
        load()
    }

    // MARK: - Queries

    func accounts(for kind: ProviderKind) -> [Account] {
        accounts.filter { $0.provider == kind }.sorted { $0.order < $1.order }
    }

    func account(_ id: UUID) -> Account? {
        accounts.first { $0.id == id }
    }

    func activeAccount(for kind: ProviderKind) -> Account? {
        active[kind].flatMap(account)
    }

    func state(_ id: UUID) -> AccountState {
        states[id] ?? .idle
    }

    func isActive(_ account: Account) -> Bool {
        active[account.provider] == account.id
    }

    /// True when the account already exists, matched on provider plus remote identity plus
    /// email. Deliberately not email alone: several accounts may share one address.
    func existing(matching identity: Identity, kind: ProviderKind) -> Account? {
        accounts.first {
            $0.provider == kind
                && $0.identity.remoteID == identity.remoteID
                && $0.identity.email == identity.email
        }
    }

    // MARK: - Mutations

    @discardableResult
    func add(identity: Identity, kind: ProviderKind, label: String, credentials: Credentials) throws -> Account {
        let nextOrder = (accounts(for: kind).map(\.order).max() ?? -1) + 1
        let account = Account(provider: kind, label: label, identity: identity, order: nextOrder)
        try Vault.store(credentials, for: account.id)
        accounts.append(account)
        save()
        return account
    }

    func update(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        save()
    }

    /// The alias is what the menu-bar ring draws, and the ring has room for two characters at
    /// most. Clamping and casing here rather than at draw time keeps what is stored and what is
    /// shown the same string.
    func setAlias(_ raw: String, for account: Account) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2).uppercased()
        var updated = account
        updated.alias = cleaned.isEmpty ? nil : String(cleaned)
        update(updated)
    }

    func remove(_ account: Account) {
        try? Vault.delete(account.id)
        accounts.removeAll { $0.id == account.id }
        if active[account.provider] == account.id { active[account.provider] = nil }
        states[account.id] = nil
        save()
    }

    func setActive(_ account: Account) {
        active[account.provider] = account.id
        save()
    }

    func credentials(for account: Account) throws -> Credentials? {
        try Vault.load(account.id)
    }

    func storeCredentials(_ credentials: Credentials, for account: Account) throws {
        try Vault.store(credentials, for: account.id)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Paths.accountsFile),
              let decoded = try? JSONDecoder.claudex.decode(PersistedAccounts.self, from: data)
        else { return }
        accounts = decoded.accounts
        active = decoded.active
        loadCachedSnapshots()
    }

    func save() {
        let payload = PersistedAccounts(accounts: accounts, active: active)
        guard let data = try? JSONEncoder.claudex.encode(payload) else { return }
        try? Paths.ensureSupportDirectory()
        try? AtomicFile.write(data, to: Paths.accountsFile)
    }

    /// Last known snapshots are cached only so the menu bar shows something on launch
    /// instead of a dash. They are never used for rotation decisions; `Rotator` requires a
    /// snapshot fetched within the freshness window.
    func cacheSnapshots() {
        let payload = states.compactMapValues(\.snapshot)
        guard let data = try? JSONEncoder.claudex.encode(payload) else { return }
        try? Paths.ensureSupportDirectory()
        try? AtomicFile.write(data, to: Paths.snapshotCache)
    }

    private func loadCachedSnapshots() {
        guard let data = try? Data(contentsOf: Paths.snapshotCache),
              let decoded = try? JSONDecoder.claudex.decode([UUID: UsageSnapshot].self, from: data)
        else { return }
        for (id, snapshot) in decoded {
            states[id] = .ok(snapshot)
        }
    }
}
