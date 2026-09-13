import Foundation
import Testing
@testable import ClaudexCore

/// When to refresh is the decision with the sharpest failure: refresh too late and a poll
/// fails, refresh an account the CLI owns and its rotated token is lost. The timing rule is
/// pure, so it is checked here; the ownership rule lives in the poll path.
@Suite struct ClaudeRefreshPolicyTests {
    private let api = ClaudeAPI()

    private func credential(expiringIn seconds: TimeInterval) -> ClaudeCredentials {
        ClaudeCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Int64((Date().timeIntervalSince1970 + seconds) * 1000),
            refreshTokenExpiresAt: nil,
            scopes: [],
            subscriptionType: nil,
            rateLimitTier: nil
        )
    }

    @Test func refreshesInsideTheLeeway() {
        #expect(api.needsRefresh(credential(expiringIn: 60), leeway: 300))
        #expect(api.needsRefresh(credential(expiringIn: -60), leeway: 300))
    }

    @Test func leavesATokenWithRoomToSpare() {
        #expect(!api.needsRefresh(credential(expiringIn: 3600), leeway: 300))
    }
}

@Suite struct CodexRefreshPolicyTests {
    private let api = CodexAPI()

    /// Codex has no stated expiry field; the expiry is a claim inside the access token, so the
    /// rule has to be exercised against a token shaped like the real one.
    private func token(exp: TimeInterval?) -> String {
        let claims: [String: Any] = exp.map { ["exp": Date().timeIntervalSince1970 + $0] } ?? [:]
        let payload = try! JSONSerialization.data(withJSONObject: claims)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    private func credential(exp: TimeInterval?, lastRefresh: Date? = nil, readable: Bool = true) -> CodexCredentials {
        CodexCredentials(
            idToken: "id",
            accessToken: readable ? token(exp: exp) : "not-a-jwt",
            refreshToken: "refresh",
            accountID: "acct",
            lastRefresh: lastRefresh
        )
    }

    @Test func refreshesInsideTheLeeway() {
        #expect(api.needsRefresh(credential(exp: 60), leeway: 300))
    }

    @Test func leavesATokenWithRoomToSpare() {
        #expect(!api.needsRefresh(credential(exp: 3600), leeway: 300))
    }

    /// With no readable expiry the rule falls back to the CLI's own eight-hour convention,
    /// and a credential that has never been refreshed is refreshed now.
    @Test func fallsBackToTheEightHourConvention() {
        #expect(api.needsRefresh(credential(exp: nil, readable: false), leeway: 300))
        #expect(api.needsRefresh(
            credential(exp: nil, lastRefresh: Date().addingTimeInterval(-9 * 3600), readable: false),
            leeway: 300
        ))
        #expect(!api.needsRefresh(
            credential(exp: nil, lastRefresh: Date().addingTimeInterval(-3600), readable: false),
            leeway: 300
        ))
    }
}

/// The store keeps one credential shape and each half of a provider works in its own. A
/// mismatch here would hand Codex tokens to the Claude endpoint, so it is refused rather than
/// coerced.
@Suite struct ProviderCredentialTests {
    private let claude = Credentials.claude(ClaudeCredentials(
        accessToken: "a", refreshToken: "r", expiresAt: 0,
        refreshTokenExpiresAt: nil, scopes: [], subscriptionType: nil, rateLimitTier: nil
    ))
    private let codex = Credentials.codex(CodexCredentials(
        idToken: "i", accessToken: "a", refreshToken: "r", accountID: "acct", lastRefresh: nil
    ))

    @Test func boxingRoundTrips() throws {
        #expect(try ClaudeCredentials(unboxing: claude).boxed == claude)
        #expect(try CodexCredentials(unboxing: codex).boxed == codex)
    }

    @Test func theWrongProvidersCredentialIsRefused() {
        #expect(throws: ClaudexError.self) { try ClaudeCredentials(unboxing: codex) }
        #expect(throws: ClaudexError.self) { try CodexCredentials(unboxing: claude) }
    }

    /// A mismatch is not a credential due a refresh: saying yes would send it to the wrong
    /// token endpoint. It surfaces on the next call that can report it properly.
    @Test func aMismatchIsNotDueARefresh() {
        let claudeProvider = AnyProvider(kind: .claude, api: ClaudeAPI(), cli: ClaudeCLI())
        let codexProvider = AnyProvider(kind: .codex, api: CodexAPI(), cli: CodexCLI())
        #expect(!claudeProvider.needsRefresh(codex, leeway: 300))
        #expect(!codexProvider.needsRefresh(claude, leeway: 300))
    }
}
