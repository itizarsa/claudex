import Foundation
import Testing
@testable import ClaudexCore

/// The two transformations that decide whether a routed request reaches the right backend as
/// the right account. Both are pure, so neither test needs a listener.
@Suite struct ProxyRequestTests {
    private func routed(remoteID: String = "acc-1", credentials: Credentials) -> RoutedAccount {
        RoutedAccount(
            id: UUID(),
            identity: Identity(
                email: "user@example.com",
                displayName: "User",
                plan: "Max",
                organization: nil,
                organizationID: nil,
                remoteID: remoteID
            ),
            credentials: credentials
        )
    }

    private var claude: Credentials {
        .claude(ClaudeCredentials(
            accessToken: "claude-access",
            refreshToken: "claude-refresh",
            expiresAt: 4_000_000_000_000,
            refreshTokenExpiresAt: nil,
            scopes: [],
            subscriptionType: "max",
            rateLimitTier: nil
        ))
    }

    private var codex: Credentials {
        .codex(CodexCredentials(
            idToken: "id",
            accessToken: "codex-access",
            refreshToken: "codex-refresh",
            accountID: "chatgpt-account",
            lastRefresh: nil
        ))
    }

    // MARK: - Headers

    @Test func stripsInboundProviderCredentials() {
        let headers = UpstreamRequest.headers(
            for: .claude,
            inbound: ["x-api-key": "someone-elses-key", "authorization": "Bearer stale", "content-type": "application/json"],
            account: routed(credentials: claude)
        )
        #expect(headers["x-api-key"] == nil)
        #expect(headers["authorization"] == "Bearer claude-access")
        #expect(headers["content-type"] == "application/json")
    }

    @Test func dropsHopByHopAndLengthHeaders() {
        let headers = UpstreamRequest.headers(
            for: .claude,
            inbound: ["connection": "keep-alive", "transfer-encoding": "chunked", "content-length": "12", "host": "127.0.0.1"],
            account: routed(credentials: claude)
        )
        for name in ["connection", "transfer-encoding", "content-length", "host"] {
            #expect(headers[name] == nil, "\(name) must not be forwarded")
        }
    }

    @Test func neverForwardsTheProxyToken() {
        let headers = UpstreamRequest.headers(
            for: .codex,
            inbound: [ProxyEndpoint.tokenHeader.lowercased(): "local-secret"],
            account: routed(credentials: codex)
        )
        #expect(headers.values.contains("local-secret") == false)
    }

    @Test func addsOAuthBetaWithoutLosingTheClientsOwn() {
        let headers = UpstreamRequest.headers(
            for: .claude,
            inbound: ["anthropic-beta": "fine-grained-tool-streaming-2025-05-14"],
            account: routed(credentials: claude)
        )
        let betas = headers["anthropic-beta"]?.split(separator: ",").map(String.init) ?? []
        #expect(betas.contains("fine-grained-tool-streaming-2025-05-14"))
        #expect(betas.contains(Endpoints.Claude.betaHeader))
    }

    @Test func doesNotDuplicateTheOAuthBeta() {
        let headers = UpstreamRequest.headers(
            for: .claude,
            inbound: ["anthropic-beta": Endpoints.Claude.betaHeader],
            account: routed(credentials: claude)
        )
        #expect(headers["anthropic-beta"] == Endpoints.Claude.betaHeader)
    }

    @Test func codexCarriesTheSelectedAccountID() {
        let headers = UpstreamRequest.headers(
            for: .codex,
            inbound: ["chatgpt-account-id": "the-account-the-cli-last-wrote"],
            account: routed(credentials: codex)
        )
        #expect(headers["chatgpt-account-id"] == "chatgpt-account")
    }

    // MARK: - URLs

    @Test func forwardsPathAndQueryUnderTheProviderBase() {
        let url = UpstreamRequest.url(for: .claude, tail: "/v1/messages", query: "beta=true")
        #expect(url?.absoluteString == "https://api.anthropic.com/v1/messages?beta=true")
    }

    @Test func codexKeepsItsBackendPathPrefix() {
        let url = UpstreamRequest.url(for: .codex, tail: "/responses", query: nil)
        #expect(url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
    }

    // MARK: - Body

    @Test func rewritesTheAccountSegmentOfClaudeMetadata() throws {
        let original = ["metadata": ["user_id": "user_abc_account_stale-uuid_session_xyz"]]
        let data = try JSONSerialization.data(withJSONObject: original)

        let rewritten = UpstreamRequest.body(for: .claude, data, account: routed(remoteID: "selected-uuid", credentials: claude))
        let object = try JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        let userID = (object?["metadata"] as? [String: Any])?["user_id"] as? String

        #expect(userID == "user_abc_account_selected-uuid_session_xyz")
    }

    @Test func leavesBodiesWithoutAccountMetadataAlone() throws {
        let data = try JSONSerialization.data(withJSONObject: ["metadata": ["user_id": "user_abc_session_xyz"]])
        #expect(UpstreamRequest.body(for: .claude, data, account: routed(credentials: claude)) == data)
    }

    @Test func leavesCodexBodiesUntouched() throws {
        // Codex thread identifiers are the CLI's conversation state; rewriting any of it
        // would break resumption.
        let data = try JSONSerialization.data(withJSONObject: ["metadata": ["user_id": "user_a_account_b_session_c"]])
        #expect(UpstreamRequest.body(for: .codex, data, account: routed(credentials: codex)) == data)
    }

    @Test func forwardsUnparseableBodiesUnchanged() {
        let data = Data("not json".utf8)
        #expect(UpstreamRequest.body(for: .claude, data, account: routed(credentials: claude)) == data)
    }
}
