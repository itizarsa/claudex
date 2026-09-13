import Foundation

enum AccountLabel {
    /// The label is the person — "Ananth" — and the organisation rides beside it as its own
    /// tag in the card. Keeping them apart is what lets the name start at the same place on
    /// every row: the organisation qualifies a seat, it does not name it.
    @MainActor
    static func suggested(for identity: Identity, kind: ProviderKind, store: AccountStore) -> String {
        let siblings = store.accounts(for: kind)
        let base = identity.personName

        let clashes = siblings.filter {
            $0.label == base || $0.label.hasPrefix("\(base) ")
        }
        // Two people of the same name in different organisations already read apart, because
        // the tag beside the name differs. Only a true twin — same name, same organisation —
        // needs a number.
        guard clashes.contains(where: { $0.identity.organizationTag == identity.organizationTag })
        else { return base }

        var index = 2
        while siblings.contains(where: { $0.label == "\(base) \(index)" }) { index += 1 }
        return "\(base) \(index)"
    }

    /// Labels are derived, never typed: an account stored under an older rule still shows the
    /// old name until it is recomputed, so every account is relabelled on load.
    static func relabel(_ accounts: [Account]) -> [Account] {
        // Two seats that differ by organisation both keep the bare name: the tag beside it
        // already tells them apart. Only a seat whose name and organisation are both taken —
        // a true twin — is numbered, so `seen` is keyed by the pair and `taken` by the label.
        var seen: Set<String> = []
        var taken: Set<String> = []
        return accounts.map { account in
            let base = account.identity.personName
            let key = "\(base)\u{0}\(account.identity.organizationTag ?? "")"
            var label = base
            if seen.contains(key) {
                var index = 2
                while taken.contains(label) {
                    label = "\(base) \(index)"
                    index += 1
                }
            }
            seen.insert(key)
            taken.insert(label)
            var relabelled = account
            relabelled.label = label
            return relabelled
        }
    }
}

extension Identity {
    /// The organisation as the card shows it, or nil when there is nothing worth showing.
    ///
    /// A personal seat's organisation is auto-named "<email>'s Organization", which is the
    /// email again with noise on it. Anything auto-named that way reads better as "Personal".
    public var organizationTag: String? {
        let name = organization?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { return nil }
        if name.hasSuffix("'s Organization") || name.hasSuffix("\u{2019}s Organization") {
            return "Personal"
        }
        return name
    }

    /// The name the provider reports, or the email's local part when it reports none. Only the
    /// first word: a full name is longer than the popover's row has room for, and the surname
    /// is rarely what tells two seats apart.
    public var personName: String {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let first = name.split(separator: " ").first { return String(first) }
        return email.split(separator: "@").first.map(String.init) ?? email
    }
}
