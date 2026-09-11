import Foundation

struct ClaudeProvider: Provider {
    let kind: ProviderKind = .claude

    private func credentials(_ credentials: Credentials) throws -> ClaudeCredentials {
        guard case .claude(let value) = credentials else {
            throw ClaudexError.unsupportedAccount("Expected Claude credentials")
        }
        return value
    }

    private func headers(_ token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": Endpoints.Claude.betaHeader,
            "Accept": "application/json",
        ]
    }

    // MARK: - Usage

    func fetchUsage(_ input: Credentials) async throws -> UsageSnapshot {
        let creds = try credentials(input)
        let response = try await HTTP.get(Endpoints.Claude.usage, headers: headers(creds.accessToken))
        let json = response.json

        // The endpoint names the windows but never states their length, so the durations the
        // names imply are used.
        let fiveHour = UsageWindow(
            percent: json["five_hour"]["utilization"].double,
            resetsAt: json["five_hour"]["resets_at"].date,
            windowSeconds: 5 * 3600
        )
        let weekly = UsageWindow(
            percent: json["seven_day"]["utilization"].double,
            resetsAt: json["seven_day"]["resets_at"].date,
            windowSeconds: 7 * 24 * 3600
        )

        let snapshot = UsageSnapshot(fiveHour: fiveHour, weekly: weekly, fetchedAt: Date())
        guard snapshot.isUsable else {
            throw ClaudexError.decoding("no five_hour or seven_day utilisation in usage response")
        }
        return snapshot
    }

    // MARK: - Identity

    func fetchIdentity(_ input: Credentials) async throws -> Identity {
        let creds = try credentials(input)
        guard !creds.accessToken.hasPrefix("sk-ant-api") else {
            throw ClaudexError.unsupportedAccount("API keys are not supported; sign in with a claude.ai subscription")
        }

        let response = try await HTTP.get(Endpoints.Claude.profile, headers: headers(creds.accessToken))
        let json = response.json
        let account = json["account"]
        let organization = json["organization"]

        guard let email = account["email"].string, let uuid = account["uuid"].string else {
            throw ClaudexError.decoding("profile response missing account email or uuid")
        }

        let seatTier = organization["seat_tier"].string
        let hasMax = account["has_claude_max"].bool ?? false
        let hasPro = account["has_claude_pro"].bool ?? false
        let isTeamSeat = seatTier != nil && organization["organization_type"].string?.hasPrefix("claude_team") == true

        guard hasMax || hasPro || isTeamSeat else {
            throw ClaudexError.unsupportedAccount("No claude.ai subscription on this account")
        }

        let plan: String
        if hasMax {
            plan = "Max"
        } else if isTeamSeat {
            plan = "Team"
        } else {
            plan = "Pro"
        }

        return Identity(
            email: email,
            displayName: account["display_name"].string ?? account["full_name"].string,
            plan: plan,
            organization: organization["name"].string,
            remoteID: uuid
        )
    }

    // MARK: - Refresh

    func needsRefresh(_ input: Credentials, leeway: TimeInterval) -> Bool {
        guard let creds = try? credentials(input) else { return false }
        return creds.expiryDate.timeIntervalSinceNow < leeway
    }

    func refresh(_ input: Credentials) async throws -> Credentials {
        let creds = try credentials(input)
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": Endpoints.Claude.clientID,
        ]

        let response: HTTP.Response
        do {
            response = try await HTTP.postJSON(Endpoints.Claude.token, body: body)
        } catch let error as ClaudexError where error.httpStatus == 404 {
            response = try await HTTP.postJSON(Endpoints.Claude.tokenFallback, body: body)
        }

        let json = response.json
        guard let accessToken = json["access_token"].string else {
            throw ClaudexError.decoding("refresh response missing access_token")
        }

        var updated = creds
        updated.accessToken = accessToken
        // The refresh token rotates. Keeping the old one would eventually lock the account out.
        if let rotated = json["refresh_token"].string { updated.refreshToken = rotated }
        if let expiresIn = json["expires_in"].double {
            updated.expiresAt = Int64((Date().timeIntervalSince1970 + expiresIn) * 1000)
        }
        if let scope = json["scope"].string {
            updated.scopes = scope.split(separator: " ").map(String.init)
        }
        return .claude(updated)
    }

    // MARK: - CLI state

    func readCurrentCLICredentials() throws -> Credentials? {
        // The file is read first on purpose. Reading Claude Code's own Keychain item from a
        // different binary triggers a GUI authorisation prompt, which blocks indefinitely in
        // any process that cannot show one. The two stores are written together and carry the
        // same bytes, so the file is an equivalent and prompt-free source.
        let data: Data
        if let file = try? Data(contentsOf: Paths.claudeCredentials) {
            data = file
        } else if Vault.useKeychain, let keychain = try ClaudeCLIKeychain.readRaw() {
            data = keychain
        } else {
            return nil
        }

        let json = try JSONView.parse(data)["claudeAiOauth"]
        guard let accessToken = json["accessToken"].string,
              let refreshToken = json["refreshToken"].string
        else { return nil }

        return .claude(ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Int64(json["expiresAt"].double ?? 0),
            refreshTokenExpiresAt: json["refreshTokenExpiresAt"].double.map { Int64($0) },
            scopes: json["scopes"].array.compactMap(\.string),
            subscriptionType: json["subscriptionType"].string,
            rateLimitTier: json["rateLimitTier"].string
        ))
    }

    func activate(_ input: Credentials, identity: Identity) throws {
        let creds = try credentials(input)

        // Preserve everything else in the file, notably the mcpOAuth block, by editing the
        // decoded object rather than writing a fresh one.
        var root: [String: Any] = [:]
        if let existing = try? Data(contentsOf: Paths.claudeCredentials),
           let object = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            root = object
        }

        var oauth: [String: Any] = [
            "accessToken": creds.accessToken,
            "refreshToken": creds.refreshToken,
            "expiresAt": creds.expiresAt,
            "scopes": creds.scopes,
        ]
        if let value = creds.refreshTokenExpiresAt { oauth["refreshTokenExpiresAt"] = value }
        if let value = creds.subscriptionType { oauth["subscriptionType"] = value }
        if let value = creds.rateLimitTier { oauth["rateLimitTier"] = value }
        root["claudeAiOauth"] = oauth

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])

        try AtomicFile.backup(Paths.claudeCredentials)
        try AtomicFile.write(data, to: Paths.claudeCredentials)

        // Claude Code keeps the same bytes in a Keychain item, and ideally both stores would
        // be updated together. Writing another application's Keychain item always raises an
        // authorisation prompt, which this app must never do from a background poll, so the
        // write only happens when the Keychain has been explicitly enabled. If the Keychain
        // write fails after the file write succeeded, the file is restored first.
        if Vault.useKeychain {
            do {
                try ClaudeCLIKeychain.writeRaw(data)
            } catch {
                let backup = Paths.claudeCredentials.appendingPathExtension("claudex-backup")
                if let previous = try? Data(contentsOf: backup) {
                    try? AtomicFile.write(previous, to: Paths.claudeCredentials)
                }
                throw error
            }
        }

        updateClaudeConfigIdentity(identity)
    }

    /// Keep `~/.claude.json`'s `oauthAccount` in step so the CLI does not display a stale
    /// identity. Best effort: a failure here is cosmetic, not a sign-in problem.
    private func updateClaudeConfigIdentity(_ identity: Identity) {
        guard let data = try? Data(contentsOf: Paths.claudeConfig),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        var oauthAccount = root["oauthAccount"] as? [String: Any] ?? [:]
        oauthAccount["emailAddress"] = identity.email
        oauthAccount["accountUuid"] = identity.remoteID
        if let name = identity.displayName { oauthAccount["displayName"] = name }
        if let organization = identity.organization { oauthAccount["organizationName"] = organization }
        root["oauthAccount"] = oauthAccount

        guard let encoded = try? JSONSerialization.data(withJSONObject: root) else { return }
        try? AtomicFile.write(encoded, to: Paths.claudeConfig)
    }
}
