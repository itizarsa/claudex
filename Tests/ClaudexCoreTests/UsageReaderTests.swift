import Foundation
import Testing
@testable import ClaudexCore

private final class StubProviderState: @unchecked Sendable {
    private let lock = NSLock()
    private var usageResults: [Result<UsageSnapshot, Error>]
    private let currentCredential: ClaudeCredentials?
    private let refreshedCredential: ClaudeCredentials
    private let refreshNeeded: Bool
    private(set) var events: [String] = []

    init(
        usageResults: [Result<UsageSnapshot, Error>],
        currentCredential: ClaudeCredentials?,
        refreshedCredential: ClaudeCredentials,
        refreshNeeded: Bool
    ) {
        self.usageResults = usageResults
        self.currentCredential = currentCredential
        self.refreshedCredential = refreshedCredential
        self.refreshNeeded = refreshNeeded
    }

    func usage() throws -> UsageSnapshot {
        try lock.withLock {
            events.append("usage")
            guard !usageResults.isEmpty else { throw ClaudexError.decoding("missing stub usage") }
            return try usageResults.removeFirst().get()
        }
    }

    func current() -> ClaudeCredentials? {
        lock.withLock {
            events.append("current")
            return currentCredential
        }
    }

    func refresh() -> ClaudeCredentials {
        lock.withLock {
            events.append("refresh")
            return refreshedCredential
        }
    }

    func needsRefresh() -> Bool { lock.withLock { refreshNeeded } }
}

private struct StubClaudeAPI: UsageAPI {
    let state: StubProviderState

    func usage(_ credential: ClaudeCredentials) async throws -> UsageSnapshot { try state.usage() }
    func identity(_ credential: ClaudeCredentials) async throws -> Identity {
        Identity(
            email: "person@example.com",
            displayName: "Person",
            plan: "Max",
            organization: nil,
            organizationID: nil,
            remoteID: "remote"
        )
    }
    func refreshed(_ credential: ClaudeCredentials) async throws -> ClaudeCredentials { state.refresh() }
    func needsRefresh(_ credential: ClaudeCredentials, leeway: TimeInterval) -> Bool { state.needsRefresh() }
}

private struct StubClaudeCLI: CLISession {
    let state: StubProviderState
    func current() throws -> ClaudeCredentials? { state.current() }
    func parse(_ data: Data) throws -> ClaudeCredentials? { nil }
    func activate(_ credential: ClaudeCredentials, identity: Identity) throws {}
}

@MainActor
@Suite struct UsageReaderTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

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

    private func snapshot(_ percent: Double = 20) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageWindow(percent: percent, resetsAt: nil, windowSeconds: 18_000),
            weekly: UsageWindow(percent: 30, resetsAt: nil, windowSeconds: 604_800),
            fetchedAt: now
        )
    }

    private func account() -> Account {
        Account(
            provider: .claude,
            label: "Person",
            identity: Identity(
                email: "person@example.com",
                displayName: "Person",
                plan: "Max",
                organization: nil,
                organizationID: nil,
                remoteID: "remote"
            )
        )
    }

    private func reader(
        account: Account,
        active: Bool,
        stored: ClaudeCredentials,
        state: StubProviderState
    ) -> (UsageReader, InMemoryCredentialStore) {
        let credentials = InMemoryCredentialStore([account.id: .claude(stored)])
        let store = AccountStore(
            accounts: [account],
            active: active ? [.claude: account.id] : [:],
            credentialStore: credentials
        )
        let provider = AnyProvider(
            kind: .claude,
            api: StubClaudeAPI(state: state),
            cli: StubClaudeCLI(state: state)
        )
        return (UsageReader(store: store, providers: ProviderRegistry([provider])), credentials)
    }

    @Test func activeReadingMirrorsLiveCredentialWithoutRefreshing() async throws {
        let account = account()
        let stored = credential("stored")
        let live = credential("live")
        let state = StubProviderState(
            usageResults: [.success(snapshot())],
            currentCredential: live,
            refreshedCredential: credential("renewed"),
            refreshNeeded: true
        )
        let (reader, credentials) = reader(account: account, active: true, stored: stored, state: state)

        #expect(try await reader.reading(for: account) == snapshot())
        #expect(credentials.load(account.id) == .claude(live))
        #expect(state.events == ["current", "usage"])
    }

    @Test func inactiveExpiringCredentialRefreshesAndPersistsBeforeUsage() async throws {
        let account = account()
        let renewed = credential("renewed")
        let state = StubProviderState(
            usageResults: [.success(snapshot())],
            currentCredential: nil,
            refreshedCredential: renewed,
            refreshNeeded: true
        )
        let (reader, credentials) = reader(
            account: account,
            active: false,
            stored: credential("stored"),
            state: state
        )

        _ = try await reader.reading(for: account)
        #expect(credentials.load(account.id) == .claude(renewed))
        #expect(state.events == ["refresh", "usage"])
    }

    @Test func inactiveUnauthorizedReadingRefreshesAndRetriesOnce() async throws {
        let account = account()
        let state = StubProviderState(
            usageResults: [.failure(ClaudexError.http(401, "expired")), .success(snapshot())],
            currentCredential: nil,
            refreshedCredential: credential("renewed"),
            refreshNeeded: false
        )
        let (reader, _) = reader(account: account, active: false, stored: credential("stored"), state: state)

        #expect(try await reader.reading(for: account) == snapshot())
        #expect(state.events == ["usage", "refresh", "usage"])
    }

    @Test func activeUnauthorizedReadingAsksCLIToRenew() async {
        let account = account()
        let state = StubProviderState(
            usageResults: [.failure(ClaudexError.http(401, "expired"))],
            currentCredential: credential("live"),
            refreshedCredential: credential("renewed"),
            refreshNeeded: false
        )
        let (reader, _) = reader(account: account, active: true, stored: credential("stored"), state: state)

        do {
            _ = try await reader.reading(for: account)
            Issue.record("Expected active credential failure")
        } catch {
            #expect(error.localizedDescription.contains("Run the CLI once"))
            #expect(!state.events.contains("refresh"))
        }
    }

    @Test func secondConsecutiveInactiveRateLimitRefreshesOnce() async throws {
        let account = account()
        let state = StubProviderState(
            usageResults: [
                .failure(ClaudexError.http(429, "limited")),
                .failure(ClaudexError.http(429, "limited")),
                .success(snapshot()),
            ],
            currentCredential: nil,
            refreshedCredential: credential("renewed"),
            refreshNeeded: false
        )
        let (reader, _) = reader(account: account, active: false, stored: credential("stored"), state: state)

        await #expect(throws: ClaudexError.self) { try await reader.reading(for: account) }
        #expect(try await reader.reading(for: account) == snapshot())
        #expect(state.events == ["usage", "usage", "refresh", "usage"])
    }
}
