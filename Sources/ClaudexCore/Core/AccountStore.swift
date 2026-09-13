import Foundation
import Observation

private struct PersistedAccounts: Codable {
    public var accounts: [Account]
    public var active: [ProviderKind: UUID]
}

@MainActor
@Observable
public final class AccountStore {
    private let credentialStore: any CredentialStore
    private let persistsMetadata: Bool
    private(set) var accounts: [Account] = []
    /// The account claudex believes each CLI is currently signed into.
    private(set) var active: [ProviderKind: UUID] = [:]
    public var states: [UUID: AccountState] = [:]
    public var settings: Settings = .load()

    public init(credentialStore: any CredentialStore) {
        self.credentialStore = credentialStore
        self.persistsMetadata = true
        load()
    }

    /// Test composition keeps account metadata and credentials wholly in memory.
    init(
        accounts: [Account],
        active: [ProviderKind: UUID] = [:],
        settings: Settings = .default,
        credentialStore: any CredentialStore
    ) {
        self.credentialStore = credentialStore
        self.persistsMetadata = false
        self.accounts = accounts
        self.active = active
        self.settings = settings
    }

    // MARK: - Queries

    public func accounts(for kind: ProviderKind) -> [Account] {
        accounts.filter { $0.provider == kind }.sorted { $0.order < $1.order }
    }

    public func account(_ id: UUID) -> Account? {
        accounts.first { $0.id == id }
    }

    public func activeAccount(for kind: ProviderKind) -> Account? {
        active[kind].flatMap(account)
    }

    public func state(_ id: UUID) -> AccountState {
        states[id] ?? .idle
    }

    public func isActive(_ account: Account) -> Bool {
        active[account.provider] == account.id
    }

    /// True when the account already exists, matched on provider plus remote identity plus
    /// email plus organisation. Deliberately not email alone: several accounts may share one
    /// address, and the same person's personal and team seats also share a remote ID.
    public func existing(matching identity: Identity, kind: ProviderKind) -> Account? {
        accounts.first {
            $0.provider == kind
                && $0.identity.remoteID == identity.remoteID
                && $0.identity.email == identity.email
                && $0.identity.organizationID == identity.organizationID
        }
    }

    // MARK: - Mutations

    @discardableResult
    public func add(identity: Identity, kind: ProviderKind, label: String, credentials: Credentials) throws -> Account {
        let nextOrder = (accounts(for: kind).map(\.order).max() ?? -1) + 1
        let account = Account(provider: kind, label: label, identity: identity, order: nextOrder)
        try credentialStore.store(credentials, for: account.id)
        accounts.append(account)
        save()
        return account
    }

    public func update(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        save()
    }

    /// The alias is what the menu-bar ring draws, and the ring has room for two characters at
    /// most. Clamping and casing here rather than at draw time keeps what is stored and what is
    /// shown the same string.
    public func setAlias(_ raw: String, for account: Account) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2).uppercased()
        var updated = account
        updated.alias = cleaned.isEmpty ? nil : String(cleaned)
        update(updated)
    }

    public func remove(_ account: Account) {
        try? credentialStore.delete(account.id)
        accounts.removeAll { $0.id == account.id }
        if active[account.provider] == account.id { active[account.provider] = nil }
        states[account.id] = nil
        save()
    }

    public func setActive(_ account: Account) {
        active[account.provider] = account.id
        save()
    }

    public func credentials(for account: Account) throws -> Credentials? {
        try credentialStore.load(account.id)
    }

    public func storeCredentials(_ credentials: Credentials, for account: Account) throws {
        try credentialStore.store(credentials, for: account.id)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Paths.accountsFile),
              let decoded = try? JSONDecoder.claudex.decode(PersistedAccounts.self, from: data)
        else { return }
        accounts = AccountLabel.relabel(decoded.accounts)
        active = decoded.active
        loadCachedSnapshots()
    }

    public func save() {
        guard persistsMetadata else { return }
        let payload = PersistedAccounts(accounts: accounts, active: active)
        guard let data = try? JSONEncoder.claudex.encode(payload) else {
            Log.write("store: could not encode \(accounts.count) account(s)")
            return
        }
        do {
            try Paths.ensureSupportDirectory()
            try AtomicFile.write(data, to: Paths.accountsFile)
        } catch {
            // An account that cannot be written is an account that disappears on relaunch,
            // which looks from the outside like the sign-in never worked.
            Log.write("store: save failed — \(error.localizedDescription)")
        }
    }

    /// Last known snapshots are cached only so the menu bar shows something on launch
    /// instead of a dash. They are never used for rotation decisions; `Rotator` requires a
    /// snapshot fetched within the freshness window.
    public func cacheSnapshots() {
        guard persistsMetadata else { return }
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
