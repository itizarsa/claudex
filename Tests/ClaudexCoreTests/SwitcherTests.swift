import Foundation
import Testing
@testable import ClaudexCore

private final class SwitchTrace: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [String] = []
    func append(_ event: String) { lock.withLock { events.append(event) } }
}

private final class RecordingCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Credentials]
    private let names: [UUID: String]
    private let trace: SwitchTrace

    init(values: [UUID: Credentials], names: [UUID: String], trace: SwitchTrace) {
        self.values = values
        self.names = names
        self.trace = trace
    }

    func store(_ credentials: Credentials, for id: UUID) {
        trace.append("store \(names[id] ?? "?")")
        lock.withLock { values[id] = credentials }
    }

    func load(_ id: UUID) -> Credentials? {
        trace.append("load \(names[id] ?? "?")")
        return lock.withLock { values[id] }
    }

    func delete(_ id: UUID) { lock.withLock { values[id] = nil } }
}

private struct SwitchingAPI: UsageAPI {
    let trace: SwitchTrace
    let refreshedCredential: ClaudeCredentials
    let identityValue: Identity

    func usage(_ credential: ClaudeCredentials) async throws -> UsageSnapshot {
        throw ClaudexError.decoding("unused")
    }
    func identity(_ credential: ClaudeCredentials) async throws -> Identity {
        trace.append("identity")
        return identityValue
    }
    func refreshed(_ credential: ClaudeCredentials) async throws -> ClaudeCredentials {
        trace.append("refresh")
        return refreshedCredential
    }
    func needsRefresh(_ credential: ClaudeCredentials, leeway: TimeInterval) -> Bool {
        trace.append("needs refresh")
        return credential.refreshToken == "incoming"
    }
}

private struct SwitchingCLI: CLISession {
    let trace: SwitchTrace
    let currentCredential: ClaudeCredentials

    func current() throws -> ClaudeCredentials? {
        trace.append("current")
        return currentCredential
    }
    func parse(_ data: Data) throws -> ClaudeCredentials? { nil }
    func activate(_ credential: ClaudeCredentials, identity: Identity) throws {
        trace.append("activate")
    }
}

@MainActor
@Suite struct SwitcherTests {
    private func identity(_ remoteID: String = "remote") -> Identity {
        Identity(
            email: "person@example.com",
            displayName: "Person",
            plan: "Max",
            organization: nil,
            organizationID: nil,
            remoteID: remoteID
        )
    }

    private func credential(_ token: String) -> ClaudeCredentials {
        ClaudeCredentials(
            accessToken: "access-\(token)",
            refreshToken: token,
            expiresAt: Int64((Date().timeIntervalSince1970 + 3600) * 1000),
            refreshTokenExpiresAt: nil,
            scopes: [],
            subscriptionType: "max",
            rateLimitTier: nil
        )
    }

    @Test func harvestsBeforeRefreshingAndActivating() async throws {
        let outgoing = Account(provider: .claude, label: "Outgoing", identity: identity(), order: 0)
        let incoming = Account(provider: .claude, label: "Incoming", identity: identity("incoming"), order: 1)
        let trace = SwitchTrace()
        let credentials = RecordingCredentialStore(
            values: [
                outgoing.id: .claude(credential("outgoing")),
                incoming.id: .claude(credential("incoming")),
            ],
            names: [outgoing.id: "outgoing", incoming.id: "incoming"],
            trace: trace
        )
        let store = AccountStore(
            accounts: [outgoing, incoming],
            active: [.claude: outgoing.id],
            credentialStore: credentials
        )
        let api = SwitchingAPI(
            trace: trace,
            refreshedCredential: credential("renewed"),
            identityValue: identity()
        )
        let cli = SwitchingCLI(trace: trace, currentCredential: credential("outgoing"))
        let switcher = Switcher(
            store: store,
            providers: ProviderRegistry([AnyProvider(kind: .claude, api: api, cli: cli)])
        )

        #expect(try await switcher.activate(incoming))
        #expect(trace.events == [
            "current",
            "load outgoing",
            "store outgoing",
            "load incoming",
            "needs refresh",
            "refresh",
            "store incoming",
            "activate",
        ])
        #expect(store.isActive(incoming))
    }

    @Test func untrackedLiveAccountStopsBeforeActivation() async {
        let outgoing = Account(provider: .claude, label: "Outgoing", identity: identity(), order: 0)
        let incoming = Account(provider: .claude, label: "Incoming", identity: identity("incoming"), order: 1)
        let trace = SwitchTrace()
        let credentials = RecordingCredentialStore(
            values: [
                outgoing.id: .claude(credential("outgoing")),
                incoming.id: .claude(credential("incoming")),
            ],
            names: [outgoing.id: "outgoing", incoming.id: "incoming"],
            trace: trace
        )
        let store = AccountStore(
            accounts: [outgoing, incoming],
            active: [.claude: outgoing.id],
            credentialStore: credentials
        )
        let api = SwitchingAPI(
            trace: trace,
            refreshedCredential: credential("renewed"),
            identityValue: identity("untracked")
        )
        let cli = SwitchingCLI(trace: trace, currentCredential: credential("unknown"))
        let switcher = Switcher(
            store: store,
            providers: ProviderRegistry([AnyProvider(kind: .claude, api: api, cli: cli)])
        )

        await #expect(throws: ClaudexError.self) { try await switcher.activate(incoming) }
        #expect(!trace.events.contains("activate"))
        #expect(store.isActive(outgoing))
    }
}
