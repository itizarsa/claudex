import Foundation
import Testing
@testable import ClaudexCore

/// Reading a CLI's credential store is the one place claudex depends on a file shape it does
/// not own. Now that parsing sits on `CLISession` rather than behind a file read, it can be
/// exercised on bytes — which is what these do.
@Suite struct ClaudeCLIParsingTests {
    private let cli = ClaudeCLI()

    private func data(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func readsTheOauthBlock() throws {
        let parsed = try cli.parse(data([
            "claudeAiOauth": [
                "accessToken": "access",
                "refreshToken": "refresh",
                "expiresAt": 1_700_000_000_000,
                "refreshTokenExpiresAt": 1_800_000_000_000,
                "scopes": ["user:inference", "user:profile"],
                "subscriptionType": "max",
                "rateLimitTier": "default",
            ],
        ]))

        let credential = try #require(parsed)
        #expect(credential.accessToken == "access")
        #expect(credential.refreshToken == "refresh")
        #expect(credential.expiresAt == 1_700_000_000_000)
        #expect(credential.refreshTokenExpiresAt == 1_800_000_000_000)
        #expect(credential.scopes == ["user:inference", "user:profile"])
        #expect(credential.subscriptionType == "max")
    }

    @Test func erasedProviderUsesItsSessionParser() throws {
        let provider = AnyProvider(kind: .claude, api: ClaudeAPI(), cli: cli)
        let bytes = data([
            "claudeAiOauth": ["accessToken": "access", "refreshToken": "refresh"],
        ])
        let expectedParsed = try cli.parse(bytes)
        let expected = try #require(expectedParsed)
        #expect(try provider.parseCLICredentials(bytes) == .claude(expected))
    }

    /// Everything but the two tokens is optional, because a store written by an older CLI is
    /// still a store claudex has to be able to use.
    @Test func toleratesAMinimalBlock() throws {
        let parsed = try cli.parse(data([
            "claudeAiOauth": ["accessToken": "access", "refreshToken": "refresh"],
        ]))

        let credential = try #require(parsed)
        #expect(credential.expiresAt == 0)
        #expect(credential.refreshTokenExpiresAt == nil)
        #expect(credential.scopes.isEmpty)
    }

    /// A store with no tokens in it is a signed-out CLI, not a failure. The caller's next step
    /// differs: signed out means offer a sign-in, failed means say what broke.
    @Test(arguments: [
        [:] as [String: Any],
        ["claudeAiOauth": [:]],
        ["claudeAiOauth": ["accessToken": "access"]],
        ["claudeAiOauth": ["refreshToken": "refresh"]],
    ])
    func missingTokensReadAsSignedOut(object: [String: Any]) throws {
        #expect(try cli.parse(data(object)) == nil)
    }

    @Test func rejectsBytesThatAreNotJSON() {
        #expect(throws: (any Error).self) { try cli.parse(Data("not json".utf8)) }
    }
}

@Suite struct CodexCLIParsingTests {
    private let cli = CodexCLI()

    private func data(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func readsTheTokenBlock() throws {
        let parsed = try cli.parse(data([
            "auth_mode": "chatgpt",
            "tokens": [
                "id_token": "id",
                "access_token": "access",
                "refresh_token": "refresh",
                "account_id": "acct",
            ],
            "last_refresh": "2026-01-02T03:04:05Z",
        ]))

        let credential = try #require(parsed)
        #expect(credential.idToken == "id")
        #expect(credential.accessToken == "access")
        #expect(credential.refreshToken == "refresh")
        #expect(credential.accountID == "acct")
        #expect(credential.lastRefresh != nil)
    }

    /// An API-key sign-in has tokens that would parse and a plan claudex cannot read usage
    /// for, so it is refused by name rather than failing later at the endpoint.
    @Test func refusesAnAPIKeySignIn() {
        #expect(throws: ClaudexError.self) {
            try cli.parse(data(["auth_mode": "apikey", "tokens": ["id_token": "id"]]))
        }
    }

    @Test(arguments: [
        ["auth_mode": "chatgpt"] as [String: Any],
        ["auth_mode": "chatgpt", "tokens": ["id_token": "id", "access_token": "access"]],
    ])
    func missingTokensReadAsSignedOut(object: [String: Any]) throws {
        #expect(try cli.parse(data(object)) == nil)
    }

    /// No `account_id` is survivable: `activate` fills it from the identity rather than
    /// refusing the account.
    @Test func missingAccountIDIsEmptyNotAbsent() throws {
        let parsed = try cli.parse(data([
            "auth_mode": "chatgpt",
            "tokens": ["id_token": "id", "access_token": "access", "refresh_token": "refresh"],
        ]))
        #expect(try #require(parsed).accountID == "")
    }
}
