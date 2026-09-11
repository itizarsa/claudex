import Foundation

/// Adopt whichever account a CLI is signed into right now. This is how existing accounts get
/// into claudex on first run, before any in-app sign-in exists.
enum CLIImport {
    struct Result {
        let account: Account
        let wasAlreadyKnown: Bool
    }

    @MainActor
    static func importCurrent(_ kind: ProviderKind, into store: AccountStore) async throws -> Result {
        let provider = Providers.of(kind)

        guard let credentials = try provider.readCurrentCLICredentials() else {
            throw ClaudexError.notSignedIn(kind)
        }

        let identity = try await provider.fetchIdentity(credentials)

        if let existing = store.existing(matching: identity, kind: kind) {
            // Refresh the stored copy: the CLI's tokens are newer than whatever we last saw.
            try store.storeCredentials(credentials, for: existing)
            store.setActive(existing)
            return Result(account: existing, wasAlreadyKnown: true)
        }

        let label = suggestedLabel(for: identity, kind: kind, store: store)
        let account = try store.add(identity: identity, kind: kind, label: label, credentials: credentials)
        store.setActive(account)
        return Result(account: account, wasAlreadyKnown: false)
    }

    /// Email alone is a poor label when several accounts share one address, so fall back to
    /// the organisation, then to a numbered suffix.
    @MainActor
    private static func suggestedLabel(for identity: Identity, kind: ProviderKind, store: AccountStore) -> String {
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
