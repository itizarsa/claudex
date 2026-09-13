import Foundation

enum AccountLabel {
    /// The organisation is what a person actually calls an account — "Superfans", not
    /// "arshath" — and it is also what differs between two seats on one email. Falls back to
    /// the email's local part when a seat has no organisation, then to a numbered suffix.
    @MainActor
    static func suggested(for identity: Identity, kind: ProviderKind, store: AccountStore) -> String {
        let siblings = store.accounts(for: kind)
        let base = display(of: identity)

        if !siblings.contains(where: { $0.label == base }) { return base }

        var index = 2
        while siblings.contains(where: { $0.label == "\(base) \(index)" }) { index += 1 }
        return "\(base) \(index)"
    }

    /// Labels are derived, never typed: an account stored under an older rule still shows the
    /// old name until it is recomputed, so every account is relabelled on load.
    static func relabel(_ accounts: [Account]) -> [Account] {
        var taken: Set<String> = []
        return accounts.map { account in
            let base = display(of: account.identity)
            var label = base
            var index = 2
            while taken.contains(label) {
                label = "\(base) \(index)"
                index += 1
            }
            taken.insert(label)
            var relabelled = account
            relabelled.label = label
            return relabelled
        }
    }
}

extension AccountLabel {
    /// A personal seat's organisation is auto-named "<email>'s Organization", which is the
    /// email again with noise on it. Anything auto-named that way reads better as "Personal".
    fileprivate static func display(of identity: Identity) -> String {
        let organization = identity.organization?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if organization.isEmpty { return localPart(of: identity.email) }
        if organization.hasSuffix("'s Organization") || organization.hasSuffix("\u{2019}s Organization") {
            return "Personal"
        }
        return organization
    }

    fileprivate static func localPart(of email: String) -> String {
        email.split(separator: "@").first.map(String.init) ?? email
    }
}
