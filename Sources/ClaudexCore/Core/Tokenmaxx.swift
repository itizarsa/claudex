import Foundation

/// One tokenmaxx account with its latest reading. tokenmaxx owns sign-in, credentials and
/// switching; claudex only draws what `tokenmaxx status` reports.
public struct UsageAccount: Identifiable, Equatable, Sendable {
    public let id: String
    public let provider: ProviderKind
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
    /// A GUI app inherits launchd's minimal PATH, which holds neither tokenmaxx nor the `bun`
    /// its shebang asks for. These are where the usual installers put them.
    private static let searchPath = [
        "\(NSHomeDirectory())/.bun/bin",
        "\(NSHomeDirectory())/.local/share/mise/shims",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ]

    private static let timeout: TimeInterval = 20

    public static func status() async throws -> [UsageAccount] {
        try parse(try await run(["status"]))
    }

    /// Asks tokenmaxx to re-probe every account's usage before the next `status`.
    public static func refresh() async throws {
        _ = try await run(["refresh"])
    }

    public static func parse(_ data: Data) throws -> [UsageAccount] {
        let json = try JSONView.parse(data)
        guard json["accounts"].exists else { throw ClaudexError.decoding("no accounts field") }

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
            guard account["enabled"].bool != false,
                  let id = account["id"].string,
                  let provider = account["provider"].string.flatMap(ProviderKind.init(tokenmaxx:))
            else { return nil }
            return UsageAccount(
                id: id,
                provider: provider,
                email: account["identity"].string ?? account["label"].string ?? "",
                plan: (account["plan"].string ?? "").capitalized,
                isActive: active.contains(id),
                health: account["health"].string ?? "ready",
                snapshot: latest[id]?.snapshot
            )
        }
    }

    /// Claude reports `session` and `weekly_all`; Codex reports `codex:primary` and
    /// `codex:secondary`. Scoped windows, such as per-model weekly limits, are left out.
    private static func snapshot(_ windows: [JSONView], observedAt: Date) -> UsageSnapshot {
        func window(_ ids: Set<String>, seconds: Double) -> UsageWindow {
            guard let match = windows.first(where: { ids.contains($0["id"].string ?? "") }) else {
                return .unknown
            }
            return UsageWindow(
                percent: match["usedPercent"].double,
                resetsAt: match["resetAt"].date,
                windowSeconds: seconds
            )
        }
        return UsageSnapshot(
            fiveHour: window(["session", "codex:primary"], seconds: 5 * 3600),
            weekly: window(["weekly_all", "codex:secondary"], seconds: 7 * 24 * 3600),
            fetchedAt: observedAt
        )
    }

    /// The blocking work runs off the caller's executor so the main actor stays free.
    private static func run(_ arguments: [String]) async throws -> Data {
        try await Task.detached { try runBlocking(arguments) }.value
    }

    private static func runBlocking(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tokenmaxx"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (searchPath + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Read both pipes while waiting: a child that fills a pipe buffer blocks forever.
        var outData = Data()
        var errorData = Data()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { outData = output.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: group) { errorData = errors.fileHandleForReading.readDataToEndOfFile() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw ClaudexError.tokenmaxx("tokenmaxx \(arguments.joined(separator: " ")) timed out")
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            // env exits 127 when it cannot find the command.
            if process.terminationStatus == 127 {
                throw ClaudexError.tokenmaxx("tokenmaxx not found. Install it with `bun add -g tokenmaxx`.")
            }
            let detail = String(decoding: errorData, as: UTF8.self)
                .split(separator: "\n").first.map(String.init) ?? "exit \(process.terminationStatus)"
            throw ClaudexError.tokenmaxx("tokenmaxx failed: \(detail)")
        }
        return outData
    }
}

extension ProviderKind {
    /// tokenmaxx names providers by vendor; Grok and any other provider are not shown.
    init?(tokenmaxx name: String) {
        switch name {
        case "anthropic": self = .claude
        case "openai": self = .codex
        default: return nil
        }
    }
}
