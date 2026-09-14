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

@MainActor
@Suite struct AccountSelectorTests {
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

    @Test func selectingReadsOnlyIncomingVaultCredential() async throws {
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
        let selector = AccountSelector(store: store)

        #expect(try await selector.select(incoming))
        #expect(trace.events == ["load incoming"])
        #expect(store.isActive(incoming))
    }

    @Test func selectingAccountWithoutVaultCredentialFails() async {
        let outgoing = Account(provider: .claude, label: "Outgoing", identity: identity(), order: 0)
        let incoming = Account(provider: .claude, label: "Incoming", identity: identity("incoming"), order: 1)
        let trace = SwitchTrace()
        let credentials = RecordingCredentialStore(
            values: [
                outgoing.id: .claude(credential("outgoing")),
            ],
            names: [outgoing.id: "outgoing", incoming.id: "incoming"],
            trace: trace
        )
        let store = AccountStore(
            accounts: [outgoing, incoming],
            active: [.claude: outgoing.id],
            credentialStore: credentials
        )
        let selector = AccountSelector(store: store)

        await #expect(throws: ClaudexError.self) { try await selector.select(incoming) }
        #expect(trace.events == ["load incoming"])
        #expect(store.isActive(outgoing))
    }
}
