import Foundation

/// One CLIProxyAPI Claude account with its latest reading. The hub owns sign-in, credentials
/// and routing; claudex draws what its management API reports.
public struct UsageAccount: Identifiable, Equatable, Sendable {
    /// The auth file's name, which the management API keys accounts by.
    public let id: String
    /// The hub's handle for the account's token, used to probe usage on its behalf.
    public let authIndex: String
    public let email: String
    /// The account the hub served most recently. The hub rotates accounts itself, so this is
    /// where traffic last went, not a pinned choice.
    public let isActive: Bool
    /// "ready" when the hub can route through the account, otherwise its own status word.
    public let health: String
    public var snapshot: UsageSnapshot?

    /// Two letters for the menu bar ring.
    public var badge: String { String(email.prefix(2)).uppercased() }
}

public enum CLIProxy {
    private static var baseURL: String {
        ProcessInfo.processInfo.environment["CLIPROXY_URL"] ?? "http://127.0.0.1:8317"
    }

    private static let secretsPath = "\(NSHomeDirectory())/.cli-proxy-api-secrets.env"

    /// The management key, read on every call so a rotated key needs no restart. A GUI app
    /// launched by launchd has no shell environment, so the secrets file is the usual source.
    private static func managementKey() throws -> String {
        if let key = ProcessInfo.processInfo.environment["CLIPROXY_MGMT"], !key.isEmpty { return key }
        let text = (try? String(contentsOfFile: secretsPath, encoding: .utf8)) ?? ""
        for line in text.split(whereSeparator: \.isNewline) {
            var line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard line.hasPrefix("CLIPROXY_MGMT=") else { continue }
            let value = line.dropFirst("CLIPROXY_MGMT=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !value.isEmpty { return value }
        }
        throw ClaudexError.cliproxy("No CLIPROXY_MGMT in ~/.cli-proxy-api-secrets.env.")
    }

    /// Lists the hub's Claude accounts with the rate-limit headers it last saw for each. Those
    /// readings are passive, so reading them costs no provider requests. With `probe`, every
    /// account's usage is also asked of Anthropic, which is the only reading an idle account has.
    public static func status(probe: Bool = false) async throws -> [UsageAccount] {
        var accounts = try parse(try await request("GET", "auth-files"))
        guard probe else { return accounts }
        for index in accounts.indices {
            if let reading = try? await usage(accounts[index]) { accounts[index].snapshot = reading }
        }
        return accounts
    }

    /// Parses a saved `GET /v0/management/auth-files` response.
    public static func parse(_ data: Data) throws -> [UsageAccount] {
        try parse(try JSONView.parse(data))
    }

    static func parse(_ json: JSONView) throws -> [UsageAccount] {
        guard json["files"].exists else { throw ClaudexError.decoding("no files field") }
        let files = json["files"].array.filter {
            $0["provider"].string == "claude" && $0["disabled"].bool != true
        }
        let lastServed = files
            .compactMap { file in file["quota"]["observed_at"].date.map { (file["name"].string, $0) } }
            .max { $0.1 < $1.1 }?.0

        return files.compactMap { file in
            guard let name = file["name"].string, let authIndex = file["auth_index"].string else { return nil }
            let status = file["status"].string ?? "active"
            let ready = status == "active" && file["unavailable"].bool != true
            let message = file["status_message"].string ?? ""
            return UsageAccount(
                id: name,
                authIndex: authIndex,
                email: file["email"].string ?? file["label"].string ?? name,
                isActive: name == lastServed,
                health: ready ? "ready" : (message.isEmpty ? status : message),
                snapshot: snapshot(file["quota"])
            )
        }
    }

    /// The `anthropic-ratelimit-unified-*` headers from the account's last response: utilization
    /// as a fraction, resets as unix seconds.
    private static func snapshot(_ quota: JSONView) -> UsageSnapshot? {
        guard let observedAt = quota["observed_at"].date else { return nil }
        let signals = quota["signals"]
        func window(_ name: String, seconds: Double) -> UsageWindow {
            guard let fraction = signals["Anthropic-Ratelimit-Unified-\(name)-Utilization"].double else {
                return .unknown
            }
            return UsageWindow(
                percent: fraction * 100,
                resetsAt: signals["Anthropic-Ratelimit-Unified-\(name)-Reset"].double
                    .map { Date(timeIntervalSince1970: $0) },
                windowSeconds: seconds
            )
        }
        return UsageSnapshot(
            fiveHour: window("5h", seconds: 5 * 3600),
            weekly: window("7d", seconds: 7 * 24 * 3600),
            fetchedAt: observedAt
        )
    }

    /// Asks Anthropic's usage endpoint through the hub's `api-call` proxy, which substitutes the
    /// account's token for `$TOKEN$` so claudex never holds it.
    private static func usage(_ account: UsageAccount) async throws -> UsageSnapshot {
        let body: [String: Any] = [
            "auth_index": account.authIndex,
            "method": "GET",
            "url": "https://api.anthropic.com/api/oauth/usage",
            "header": ["Authorization": "Bearer $TOKEN$", "anthropic-beta": "oauth-2025-04-20"],
        ]
        let response = try await request("POST", "api-call", body: body)
        guard response["status_code"].int == 200, let text = response["body"].string else {
            throw ClaudexError.cliproxy("usage probe for \(account.email) failed")
        }
        return try parseUsage(Data(text.utf8))
    }

    /// Parses Anthropic's `/api/oauth/usage` body, whose utilization is already a percentage.
    static func parseUsage(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let json = try JSONView.parse(data)
        func window(_ key: String, seconds: Double) -> UsageWindow {
            guard let percent = json[key]["utilization"].double else { return .unknown }
            return UsageWindow(percent: percent, resetsAt: json[key]["resets_at"].date, windowSeconds: seconds)
        }
        return UsageSnapshot(
            fiveHour: window("five_hour", seconds: 5 * 3600),
            weekly: window("seven_day", seconds: 7 * 24 * 3600),
            fetchedAt: fetchedAt
        )
    }

    private static func request(_ method: String, _ path: String, body: Any? = nil) async throws -> JSONView {
        guard let url = URL(string: "\(baseURL)/v0/management/\(path)") else {
            throw ClaudexError.cliproxy("bad CLIProxyAPI URL \(baseURL)")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(try managementKey())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw ClaudexError.cliproxy("CLIProxyAPI is not running. Start it with `brew services start cliproxyapi`.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw ClaudexError.cliproxy("CLIProxyAPI rejected the management key.")
        }
        guard status == 200 else { throw ClaudexError.cliproxy("CLIProxyAPI \(path) returned \(status)") }
        return try JSONView.parse(data)
    }
}
