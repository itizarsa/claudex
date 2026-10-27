import Foundation

/// One CLIProxyAPI Claude account with its latest reading. The hub owns sign-in, credentials
/// and routing; claudex draws what its management API reports.
public struct UsageAccount: Identifiable, Equatable, Sendable {
    /// The auth file's name, which the management API keys accounts by.
    public let id: String
    /// The hub's handle for the account, which quota fetches name it by.
    public let authIndex: String
    public let email: String
    /// "Personal" or "Team", from the account's organisation. Empty when unknown.
    public var plan: String = ""
    /// The account the reset-first plugin sends the next request to. See `markActive`.
    public var isActive = false
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
    /// readings are passive, so reading them costs no provider requests. With `fetch`, the hub
    /// also fetches each account's quota now, through its quota provider (the reset-first
    /// plugin), which is the only reading an idle account has.
    public static func status(fetch: Bool = false) async throws -> [UsageAccount] {
        var accounts = try parse(try await request("GET", "auth-files"))
        guard fetch else { return accounts }
        for index in accounts.indices {
            let body: [String: Any] = ["auth_index": accounts[index].authIndex]
            if let response = try? await request("POST", "quota/fetch", body: body) {
                accounts[index].snapshot = parseQuota(response)
            }
        }
        markActive(&accounts)
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
        var accounts: [UsageAccount] = files.compactMap { file in
            guard let name = file["name"].string, let authIndex = file["auth_index"].string else { return nil }
            let status = file["status"].string ?? "active"
            let ready = status == "active" && file["unavailable"].bool != true
            let message = health(file)
            let email = file["email"].string ?? file["label"].string ?? name
            return UsageAccount(
                id: name,
                authIndex: authIndex,
                email: email,
                plan: plan(organization: organization(file["path"].string), email: email),
                health: ready ? "ready" : (message.isEmpty ? status : message),
                snapshot: snapshot(file["quota"])
            )
        }
        markActive(&accounts)
        return accounts
    }

    /// Why the hub isn't routing through the account, in words. A quota cooldown is the usual
    /// case; otherwise `status_message` is often the provider's raw error body, whose own
    /// message is the readable part.
    private static func health(_ file: JSONView) -> String {
        if file["cooldowns"].array.contains(where: { ($0["reason"].string ?? "").contains("quota") }) {
            return "rate limited"
        }
        let message = file["status_message"].string ?? ""
        if let data = message.data(using: .utf8), let body = try? JSONView.parse(data),
           let text = body["error"]["message"].string {
            return text
        }
        return message
    }

    /// Parses `POST /v0/management/quota/fetch`: buckets "5h" and "7d", each with the fraction
    /// left and an ISO reset time.
    static func parseQuota(_ json: JSONView, fetchedAt: Date = Date()) -> UsageSnapshot {
        let buckets = json["groups"].array.flatMap { $0["buckets"].array }
        func window(_ name: String, seconds: Double) -> UsageWindow {
            guard let bucket = buckets.first(where: { $0["window"].string == name }),
                  let remaining = bucket["remainingFraction"].double
            else { return .unknown }
            return UsageWindow(percent: (1 - remaining) * 100, resetsAt: bucket["resetTime"].date, windowSeconds: seconds)
        }
        return UsageSnapshot(
            fiveHour: window("5h", seconds: 5 * 3600),
            weekly: window("7d", seconds: 7 * 24 * 3600),
            fetchedAt: fetchedAt
        )
    }

    /// Marks the account the reset-first scheduler plugin (itizarsa/cliproxy-plugin) picks:
    /// among those the hub can route through now, the soonest weekly reset wins, since quota
    /// left at a reset is lost. Accounts at `spent` weekly use rank after the rest, accounts with
    /// no weekly reading after those, and ties go by id.
    public static func markActive(_ accounts: inout [UsageAccount], spent: Double = 98, now: Date = Date()) {
        func key(_ account: UsageAccount) -> Double? {
            guard account.health == "ready" else { return nil }
            // The hub cools an account at its 5-hour limit, so it isn't offered to the plugin.
            let fiveHour = account.snapshot?.fiveHour
            let capped = (fiveHour?.percent ?? 0) >= 100
            if capped, let reset = fiveHour?.resetsAt, reset > now { return nil }
            guard let weekly = account.snapshot?.weekly,
                  let percent = weekly.percent,
                  let reset = weekly.resetsAt,
                  reset > now
            else { return Double.infinity }
            if percent >= spent { return Double.greatestFiniteMagnitude }
            return reset.timeIntervalSince1970
        }
        var pick: (id: String, key: Double)?
        for account in accounts {
            guard let key = key(account) else { continue }
            if let best = pick, best.key < key || (best.key == key && best.id < account.id) { continue }
            pick = (account.id, key)
        }
        for index in accounts.indices {
            accounts[index].isActive = accounts[index].id == pick?.id
        }
    }

    /// The `organization_name` in the hub's auth file for the account. The management API
    /// doesn't list it, so the file is read; only this field is taken from it.
    private static func organization(_ path: String?) -> String? {
        guard let path, let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONView.parse(data))?["organization_name"].string
    }

    /// Anthropic names a personal organisation "<email>'s Organization"; any other is a team.
    static func plan(organization: String?, email: String) -> String {
        guard let organization, !organization.isEmpty else { return "" }
        return organization.lowercased().hasPrefix(email.lowercased()) ? "Personal" : "Team"
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
