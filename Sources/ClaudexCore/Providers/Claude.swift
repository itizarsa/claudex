import Foundation

/// claude.ai's usage and profile endpoints, and the OAuth refresh behind them.
public struct ClaudeAPI: UsageAPI {
    public init() {}

    private func headers(_ token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": Endpoints.Claude.betaHeader,
            "Accept": "application/json",
        ]
    }

    // MARK: - Usage

    public func usage(_ credential: ClaudeCredentials) async throws -> UsageSnapshot {
        let response = try await HTTP.get(Endpoints.Claude.usage, headers: headers(credential.accessToken))
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

    public func identity(_ credential: ClaudeCredentials) async throws -> Identity {
        guard !credential.accessToken.hasPrefix("sk-ant-api") else {
            throw ClaudexError.unsupportedAccount("API keys are not supported; sign in with a claude.ai subscription")
        }

        let response = try await HTTP.get(Endpoints.Claude.profile, headers: headers(credential.accessToken))
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
            organizationID: organization["uuid"].string,
            remoteID: uuid
        )
    }

    // MARK: - Refresh

    public func needsRefresh(_ credential: ClaudeCredentials, leeway: TimeInterval) -> Bool {
        credential.expiryDate.timeIntervalSinceNow < leeway
    }

    public func refreshed(_ credential: ClaudeCredentials) async throws -> ClaudeCredentials {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": credential.refreshToken,
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

        var updated = credential
        updated.accessToken = accessToken
        // The refresh token rotates. Keeping the old one would eventually lock the account out.
        if let rotated = json["refresh_token"].string { updated.refreshToken = rotated }
        if let expiresIn = json["expires_in"].double {
            updated.expiresAt = Int64((Date().timeIntervalSince1970 + expiresIn) * 1000)
        }
        if let scope = json["scope"].string {
            updated.scopes = scope.split(separator: " ").map(String.init)
        }
        return updated
    }
}

/// Read-only access to Claude Code's own credential store.
public struct ClaudeCLI: CLISession {
    public init() {}

    public func current() throws -> ClaudeCredentials? {
        // The file is read first because Claude Code does the same. Both stores carry the same
        // bytes; the Keychain remains the fallback when the file is absent.
        let data: Data
        if let file = try? Data(contentsOf: Paths.claudeCredentials) {
            data = file
        } else if let keychain = try ClaudeCLIKeychain.readRaw() {
            data = keychain
        } else {
            return nil
        }

        return try parse(data)
    }

    public func parse(_ data: Data) throws -> ClaudeCredentials? {
        let json = try JSONView.parse(data)["claudeAiOauth"]
        guard let accessToken = json["accessToken"].string,
              let refreshToken = json["refreshToken"].string
        else { return nil }

        return ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Int64(json["expiresAt"].double ?? 0),
            refreshTokenExpiresAt: json["refreshTokenExpiresAt"].double.map { Int64($0) },
            scopes: json["scopes"].array.compactMap(\.string),
            subscriptionType: json["subscriptionType"].string,
            rateLimitTier: json["rateLimitTier"].string
        )
    }

}
