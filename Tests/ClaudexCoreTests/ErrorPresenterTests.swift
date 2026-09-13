import Foundation
import Testing
@testable import ClaudexCore

/// Raw API bodies never reach the UI. These assertions are about what a person can do next:
/// "sign in again" is an instruction, a truncated JSON blob is not.
@Suite struct ErrorPresenterTests {
    @Test(arguments: [
        (ClaudexError.http(401, "{}"), "Signed out. Sign in again in the CLI."),
        (.http(403, "{}"), "Signed out. Sign in again in the CLI."),
        (.http(429, "{}"), "Rate limited by the API. Retrying shortly."),
        (.http(503, "{}"), "The service is unavailable. Retrying shortly."),
        (.http(418, "{}"), "Request failed (HTTP 418)."),
        (.decoding("no five_hour"), "The usage API returned an unfamiliar response."),
        (.notSignedIn(.codex), "Codex CLI is not signed in."),
        (.unsupportedAccount("No claude.ai subscription"), "No claude.ai subscription"),
    ])
    func typedErrorsBecomeInstructions(error: ClaudexError, expected: String) {
        #expect(ErrorPresenter.message(error) == expected)
    }

    /// The string overload exists for errors that arrived as text from a CLI rather than as a
    /// typed failure, and it has to recognise the same three conditions.
    @Test(arguments: [
        ("HTTP 401 unauthorized", "Signed out. Sign in again in the CLI."),
        ("HTTP 429 too many", "Rate limited by the API. Retrying shortly."),
        ("Rate Limit exceeded", "Rate limited by the API. Retrying shortly."),
        ("HTTP 502 bad gateway", "The service is unavailable. Retrying shortly."),
    ])
    func textualErrorsAreRecognisedToo(raw: String, expected: String) {
        #expect(ErrorPresenter.message(raw) == expected)
    }

    /// Anything unrecognised is passed through rather than swallowed — an unfamiliar message
    /// is still more use than a generic one.
    @Test func unrecognisedTextIsKept() {
        #expect(ErrorPresenter.message("could not reach the network") == "could not reach the network")
    }
}
