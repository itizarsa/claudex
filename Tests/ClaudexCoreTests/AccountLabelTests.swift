import Foundation
import Testing
@testable import ClaudexCore

/// Labels are derived and recomputed on every load, so `relabel` is what a person actually
/// reads in the popover. It has to be stable — the same accounts in the same order must give
/// the same names every launch — and it has to keep two seats apart.
@Suite struct AccountLabelTests {
    private func account(email: String, organization: String?) -> Account {
        Account(
            provider: .claude,
            label: "stale",
            identity: Identity(
                email: email,
                displayName: nil,
                plan: "Max",
                organization: organization,
                organizationID: organization,
                remoteID: "remote"
            )
        )
    }

    /// The organisation is what a person calls an account, and it wins over the email.
    @Test func namesByOrganisation() {
        let labels = AccountLabel.relabel([account(email: "a@b.com", organization: "Superfans")])
        #expect(labels.map(\.label) == ["Superfans"])
    }

    /// A personal seat is auto-named "<email>'s Organization", which is the email again with
    /// noise on it. Both apostrophes appear in the wild.
    @Test(arguments: ["a@b.com's Organization", "a@b.com\u{2019}s Organization"])
    func personalSeatsAreNamedPersonal(organization: String) {
        let labels = AccountLabel.relabel([account(email: "a@b.com", organization: organization)])
        #expect(labels.map(\.label) == ["Personal"])
    }

    /// No organisation, or a blank one, falls back to the email's local part.
    @Test(arguments: [nil, "", "   "] as [String?])
    func fallsBackToTheEmail(organization: String?) {
        let labels = AccountLabel.relabel([account(email: "arshath@b.com", organization: organization)])
        #expect(labels.map(\.label) == ["arshath"])
    }

    /// Two seats that resolve to the same name get numbered from 2, and the first keeps the
    /// bare name. Anything else would rename an account a person already recognises.
    @Test func collisionsAreNumberedFromTwo() {
        let labels = AccountLabel.relabel([
            account(email: "a@b.com", organization: "Superfans"),
            account(email: "c@d.com", organization: "Superfans"),
            account(email: "e@f.com", organization: "Superfans"),
        ])
        #expect(labels.map(\.label) == ["Superfans", "Superfans 2", "Superfans 3"])
    }

    /// Relabelling is the whole point: whatever was stored under an older rule is replaced.
    @Test func theStoredLabelIsDiscarded() {
        let labels = AccountLabel.relabel([account(email: "a@b.com", organization: "Superfans")])
        #expect(labels.first?.label != "stale")
    }
}
