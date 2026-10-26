import Foundation

/// One tokenmaxx account with its latest reading. tokenmaxx owns sign-in, credentials and
/// switching; claudex draws what its daemon reports and asks it to switch.
public struct UsageAccount: Identifiable, Equatable, Sendable {
    public let id: String
    public let email: String
    public let plan: String
    public let isActive: Bool
    /// tokenmaxx's own word for the account, "ready" when it can serve requests.
    public let health: String
    public let snapshot: UsageSnapshot?

    /// Two letters for the menu bar ring.
    public var badge: String { String(email.prefix(2)).uppercased() }
}

public enum Tokenmaxx {
    /// The tokenmaxx daemon's JSON-RPC socket, the same one tokenmaxx's own app reads. Talking
    /// to it directly spares a GUI app from finding `tokenmaxx`, `node` and `bun` on launchd's
    /// minimal PATH.
    private static var socketPath: String {
        let home = ProcessInfo.processInfo.environment["TOKENMAXX_HOME"]
            ?? "\(NSHomeDirectory())/.tokenmaxx"
        return "\(home)/runtime/manager.sock"
    }

    public static func status() async throws -> [UsageAccount] {
        let snapshot = try await call("dashboard/analytics", timeout: 15)["snapshot"]
        guard snapshot["accounts"].exists else { throw ClaudexError.decoding("no accounts field") }
        return parse(snapshot)
    }

    /// Asks tokenmaxx to re-probe every account's usage before the next `status`.
    public static func refresh() async throws {
        _ = try await call("usage/refresh", timeout: 60)
    }

    /// Makes `account` the one tokenmaxx routes its provider's requests through.
    public static func switchTo(_ account: UsageAccount) async throws {
        let params: [String: Any] = [
            "provider": "anthropic",
            "reason": "manual",
            "targetAccountId": account.id,
        ]
        _ = try await call("provider/switch", params: params, timeout: 30)
    }

    /// Parses a saved `tokenmaxx status` output, which has the daemon snapshot's shape.
    public static func parse(_ data: Data) throws -> [UsageAccount] {
        let json = try JSONView.parse(data)
        guard json["accounts"].exists else { throw ClaudexError.decoding("no accounts field") }
        return parse(json)
    }

    static func parse(_ json: JSONView) -> [UsageAccount] {
        let active = Set(json["providers"].array.compactMap { $0["activeAccountId"].string })

        // `usage` can hold readings for accounts since removed, and more than one per account;
        // the newest reading for a listed account wins.
        var latest: [String: (observedAt: Date, snapshot: UsageSnapshot)] = [:]
        for entry in json["usage"].array {
            guard let id = entry["accountId"].string else { continue }
            let observedAt = entry["observedAt"].date ?? .distantPast
            if let existing = latest[id], existing.observedAt >= observedAt { continue }
            latest[id] = (observedAt, snapshot(entry["windows"].array, observedAt: observedAt))
        }

        return json["accounts"].array.compactMap { account in
            // tokenmaxx names providers by vendor; only Anthropic's are shown.
            guard account["enabled"].bool != false,
                  account["provider"].string == "anthropic",
                  let id = account["id"].string
            else { return nil }
            return UsageAccount(
                id: id,
                email: account["identity"].string ?? account["label"].string ?? "",
                plan: (account["plan"].string ?? "").capitalized,
                isActive: active.contains(id),
                health: account["health"].string ?? "ready",
                snapshot: latest[id]?.snapshot
            )
        }
    }

    /// Claude reports `session` and `weekly_all`. Scoped windows, such as per-model weekly
    /// limits, are left out.
    private static func snapshot(_ windows: [JSONView], observedAt: Date) -> UsageSnapshot {
        func window(_ id: String, seconds: Double) -> UsageWindow {
            guard let match = windows.first(where: { $0["id"].string == id }) else {
                return .unknown
            }
            return UsageWindow(
                percent: match["usedPercent"].double,
                resetsAt: match["resetAt"].date,
                windowSeconds: seconds
            )
        }
        return UsageSnapshot(
            fiveHour: window("session", seconds: 5 * 3600),
            weekly: window("weekly_all", seconds: 7 * 24 * 3600),
            fetchedAt: observedAt
        )
    }

    /// The blocking work runs off the caller's executor so the main actor stays free.
    private static func call(_ method: String, params: Any = NSNull(), timeout: Int) async throws -> JSONView {
        try await Task.detached { try callBlocking(method, params: params, timeout: timeout) }.value
    }

    /// One request per connection: a JSON line out, a JSON line back.
    private static func callBlocking(_ method: String, params: Any, timeout: Int) throws -> JSONView {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClaudexError.tokenmaxx("could not open a socket") }
        defer { close(fd) }

        var limit = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        // A daemon that closes the socket mid-write must not kill the app with SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ClaudexError.tokenmaxx("tokenmaxx socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw ClaudexError.tokenmaxx("tokenmaxx is not running. Start it with `tokenmaxx daemon start`.")
        }

        let request: [String: Any] = ["id": 1, "method": method, "params": params]
        let line = try JSONSerialization.data(withJSONObject: request) + Data("\n".utf8)
        let sent = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == line.count else { throw ClaudexError.tokenmaxx("tokenmaxx \(method) failed to send") }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !response.contains(UInt8(ascii: "\n")) {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                response.append(contentsOf: buffer[..<count])
            } else if count == 0 {
                break
            } else if errno == EAGAIN {
                throw ClaudexError.tokenmaxx("tokenmaxx \(method) timed out")
            } else {
                throw ClaudexError.tokenmaxx("tokenmaxx \(method) failed: \(String(cString: strerror(errno)))")
            }
        }

        let json = try JSONView.parse(response)
        if let message = json["error"]["message"].string {
            throw ClaudexError.tokenmaxx("tokenmaxx: \(message)")
        }
        return json["result"]
    }
}

