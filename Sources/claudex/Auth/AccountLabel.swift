import Foundation

enum AccountLabel {
    /// Email alone is a poor label when several accounts share one address, so fall back to
    /// the organisation, then to a numbered suffix.
    @MainActor
    static func suggested(for identity: Identity, kind: ProviderKind, store: AccountStore) -> String {
        let siblings = store.accounts(for: kind)
        let base = identity.email.split(separator: "@").first.map(String.init) ?? identity.email

        if !siblings.contains(where: { $0.label == base }) { return base }

        if let organization = identity.organization {
            let withOrg = "\(base) (\(organization))"
            if !siblings.contains(where: { $0.label == withOrg }) { return withOrg }
        }

        var index = 2
        while siblings.contains(where: { $0.label == "\(base) \(index)" }) { index += 1 }
        return "\(base) \(index)"
    }
}
