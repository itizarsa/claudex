import Foundation
import Testing
@testable import ClaudexCore

/// Labels are derived and recomputed on every load, so `relabel` is what a person actually
/// reads in the popover. The label names the person; the organisation rides beside it as its
/// own tag, which is what lets two seats keep the same bare name.
@Suite struct AccountLabelTests {
    private func account(email: String, organization: String?, name: String? = nil) -> Account {
        Account(
            provider: .claude,
            label: "stale",
            identity: Identity(
                email: email,
                displayName: name,
                plan: "Max",
                organization: organization,
                organizationID: organization,
                remoteID: "remote"
            )
        )
    }

    /// The label is the person, not the organisation: the card shows the organisation itself.
    @Test func namesByPerson() {
        let labels = AccountLabel.relabel([
            account(email: "a@b.com", organization: "Superfans", name: "Ananth")
        ])
        #expect(labels.map(\.label) == ["Ananth"])
    }

    /// Only the first name. A full name overruns the row, and the surname rarely separates
    /// two seats that the first name does not.
    @Test func onlyTheFirstName() {
        let labels = AccountLabel.relabel([
            account(email: "a@b.com", organization: "Superfans", name: "Ananth Kumar")
        ])
        #expect(labels.map(\.label) == ["Ananth"])
    }

    /// No reported name falls back to the email's local part, which is the half of the address
    /// that identifies the person.
    @Test(arguments: [nil, "", "   "] as [String?])
    func fallsBackToTheEmail(name: String?) {
        let labels = AccountLabel.relabel([
            account(email: "ananth@b.com", organization: "Superfans", name: name)
        ])
        #expect(labels.map(\.label) == ["ananth"])
    }

    /// One person's two seats keep one name. The organisation tag beside it is what says which
    /// seat this is, so numbering them would repeat a distinction the card already draws.
    @Test func twoSeatsOfOnePersonKeepTheName() {
        let labels = AccountLabel.relabel([
            account(email: "arshath@b.com", organization: "Superfans", name: "Arshath"),
            account(email: "arshath@b.com", organization: "Northwind", name: "Arshath"),
        ])
        #expect(labels.map(\.label) == ["Arshath", "Arshath"])
    }

    /// A true twin — same name, same organisation — has nothing else to go on, so it is
    /// numbered from 2 and the first keeps the bare name.
    @Test func twinsInOneOrganisationAreNumbered() {
        let labels = AccountLabel.relabel([
            account(email: "arshath@b.com", organization: "Superfans", name: "Arshath"),
            account(email: "arshath+2@b.com", organization: "Superfans", name: "Arshath"),
            account(email: "arshath+3@b.com", organization: "Superfans", name: "Arshath"),
        ])
        #expect(labels.map(\.label) == ["Arshath", "Arshath 2", "Arshath 3"])
    }

    /// Relabelling is the whole point: whatever was stored under an older rule is replaced.
    @Test func theStoredLabelIsDiscarded() {
        let labels = AccountLabel.relabel([
            account(email: "a@b.com", organization: "Superfans", name: "Ananth")
        ])
        #expect(labels.first?.label != "stale")
    }
}

/// The tag beside the name. It is drawn as its own element, so what it says is decided here
/// rather than inside the view.
@Suite struct OrganizationTagTests {
    private func identity(email: String, organization: String?) -> Identity {
        Identity(
            email: email,
            displayName: nil,
            plan: "Max",
            organization: organization,
            organizationID: organization,
            remoteID: "remote"
        )
    }

    @Test func showsTheOrganisation() {
        #expect(identity(email: "a@b.com", organization: "Superfans").organizationTag == "Superfans")
    }

    /// A personal seat is auto-named "<email>'s Organization", which is the email again with
    /// noise on it. Both apostrophes appear in the wild.
    @Test(arguments: ["a@b.com's Organization", "a@b.com\u{2019}s Organization"])
    func personalSeatsReadAsPersonal(organization: String) {
        #expect(identity(email: "a@b.com", organization: organization).organizationTag == "Personal")
    }

    /// No organisation means no tag, rather than an empty one leaving a gap beside the name.
    @Test(arguments: [nil, "", "   "] as [String?])
    func noOrganisationMeansNoTag(organization: String?) {
        #expect(identity(email: "a@b.com", organization: organization).organizationTag == nil)
    }
}
