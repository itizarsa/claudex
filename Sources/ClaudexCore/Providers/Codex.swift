import Foundation

/// ChatGPT's rate-limit endpoint, the identity carried in the id token, and the OAuth refresh
/// behind both.
public struct CodexAPI: UsageAPI {
    public init() {}

    // MARK: - Usage

    public func usage(_ credential: CodexCredentials) async throws -> UsageSnapshot {
        let response = try await HTTP.get(Endpoints.Codex.usage, headers: [
            "Authorization": "Bearer \(credential.accessToken)",
            "chatgpt-account-id": credential.accountID,
            "Accept": "application/json",
        ])

        let rateLimit = response.json["rate_limit"]
        let snapshot = UsageSnapshot(
            fiveHour: window(rateLimit["primary_window"]),
            weekly: window(rateLimit["secondary_window"]),
            fetchedAt: Date()
        )
        guard snapshot.isUsable else {
            throw ClaudexError.decoding("no rate_limit windows in usage response")
        }
        return snapshot
    }

    /// `reset_at` is unix seconds; `reset_after_seconds` is the relative fallback.
    private func window(_ json: JSONView) -> UsageWindow {
        guard json.exists else { return .unknown }
        var resetsAt = json["reset_at"].date
        if resetsAt == nil, let after = json["reset_after_seconds"].double {
            resetsAt = Date().addingTimeInterval(after)
        }
        return UsageWindow(
            percent: json["used_percent"].double,
            resetsAt: resetsAt,
            windowSeconds: json["limit_window_seconds"].double
        )
    }

    // MARK: - Identity

    public func identity(_ credential: CodexCredentials) async throws -> Identity {
        let claims = try JWT.claims(credential.idToken)
        let auth = claims["https://api.openai.com/auth"]

        guard let email = claims["email"].string else {
            throw ClaudexError.decoding("id_token has no email claim")
        }
        let accountID = auth["chatgpt_account_id"].string ?? credential.accountID
        let plan = auth["chatgpt_plan_type"].string ?? "unknown"

        guard plan.lowercased() != "free" else {
            throw ClaudexError.unsupportedAccount("Codex needs a paid ChatGPT plan")
        }

        let organization = auth["organizations"].array.first { $0["is_default"].bool == true }

        return Identity(
            email: email,
            displayName: claims["name"].string,
            plan: plan.capitalized,
            organization: organization?["title"].string,
            organizationID: organization?["id"].string,
            remoteID: accountID
        )
    }

    // MARK: - Refresh

    public func needsRefresh(_ credential: CodexCredentials, leeway: TimeInterval) -> Bool {
        guard let claims = try? JWT.claims(credential.accessToken), let expiry = claims["exp"].double else {
            // No readable expiry, so fall back to the CLI's own convention of refreshing
            // roughly every eight hours.
            guard let last = credential.lastRefresh else { return true }
            return Date().timeIntervalSince(last) > 8 * 3600
        }
        return Date(timeIntervalSince1970: expiry).timeIntervalSinceNow < leeway
    }

    public func refreshed(_ credential: CodexCredentials) async throws -> CodexCredentials {
        let response = try await HTTP.postJSON(Endpoints.Codex.token, body: [
            "client_id": Endpoints.Codex.clientID,
            "grant_type": "refresh_token",
            "refresh_token": credential.refreshToken,
            "scope": "openid profile email",
        ])

        let json = response.json
        guard let accessToken = json["access_token"].string else {
            throw ClaudexError.decoding("refresh response missing access_token")
        }

        var updated = credential
        updated.accessToken = accessToken
        if let idToken = json["id_token"].string { updated.idToken = idToken }
        if let rotated = json["refresh_token"].string { updated.refreshToken = rotated }
        updated.lastRefresh = Date()
        return updated
    }
}

/// Read-only access to Codex CLI's own credential store.
public struct CodexCLI: CLISession {
    public init() {}

    public func current() throws -> CodexCredentials? {
        guard let data = try? Data(contentsOf: Paths.codexAuth) else { return nil }
        return try parse(data)
    }

    public func parse(_ data: Data) throws -> CodexCredentials? {
        let json = try JSONView.parse(data)

        guard json["auth_mode"].string == "chatgpt" else {
            throw ClaudexError.unsupportedAccount("Codex CLI is using an API key; sign in with ChatGPT instead")
        }

        let tokens = json["tokens"]
        guard let idToken = tokens["id_token"].string,
              let accessToken = tokens["access_token"].string,
              let refreshToken = tokens["refresh_token"].string
        else { return nil }

        return CodexCredentials(
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountID: tokens["account_id"].string ?? "",
            lastRefresh: json["last_refresh"].date
        )
    }

}

enum JWT {
    /// Reads the payload without verifying the signature. The token came from the CLI's own
    /// storage or straight from the token endpoint, so this is used for display only, never
    /// as a trust decision.
    static func claims(_ token: String) throws -> JSONView {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { throw ClaudexError.decoding("malformed JWT") }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }

        guard let data = Data(base64Encoded: base64) else {
            throw ClaudexError.decoding("JWT payload is not valid base64")
        }
        return try JSONView.parse(data)
    }
}
