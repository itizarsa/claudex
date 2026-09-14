import Foundation

/// What claudex found in one CLI's configuration.
public enum RoutingStatus: Equatable, Sendable {
    /// No routing of any kind. Installing is safe.
    case absent
    /// Routed here, at this endpoint. Nothing to do.
    case installed
    /// Routed to a claudex endpoint that no longer exists — the usual case after a restart,
    /// since the port is ephemeral. Installing repairs it.
    case stale(String)
    /// Routed somewhere claudex did not put it, or a claudex block someone has since edited.
    /// Installing would destroy a decision that was not ours, so it refuses.
    case foreign(String)

    public var isInstalled: Bool { self == .installed }
}

/// Reads and writes the two native CLI configuration files.
///
/// Separate from `AccountProxy` because the failure modes have nothing in common. The proxy
/// fails for the duration of a request; this fails by leaving a config file the user has to
/// repair by hand, possibly on a machine where claudex is no longer running. That difference
/// is what makes install and uninstall explicit user actions rather than launch behaviour.
public protocol CLIRoutingInstaller: Sendable {
    func status(for kind: ProviderKind, endpoint: ProxyEndpoint?) throws -> RoutingStatus
    func install(_ endpoint: ProxyEndpoint, for kind: ProviderKind) throws
    func uninstall(for kind: ProviderKind) throws
}

/// What one CLI's configuration held before claudex touched it.
struct RoutingBackup: Codable, Equatable, Sendable {
    /// Nil means the key was absent, which is different from present-and-empty: restoring the
    /// difference wrong leaves the CLI pointed at "".
    var previousBaseURL: String?
    var previousModelProvider: String?
    var installedAt: Date
}

public struct NativeCLIRoutingInstaller: CLIRoutingInstaller {
    private let claudeSettings: URL
    private let codexConfig: URL
    private let backups: URL

    /// Production paths. Named at the call site rather than defaulted, so a test cannot reach
    /// the real `~/.claude` or `~/.codex` by forgetting an argument.
    public static func live() -> NativeCLIRoutingInstaller {
        NativeCLIRoutingInstaller(
            claudeSettings: Paths.claudeSettings,
            codexConfig: Paths.codexConfig,
            backups: Paths.routingFile
        )
    }

    public init(claudeSettings: URL, codexConfig: URL, backups: URL) {
        self.claudeSettings = claudeSettings
        self.codexConfig = codexConfig
        self.backups = backups
    }

    // MARK: - Status

    public func status(for kind: ProviderKind, endpoint: ProxyEndpoint?) throws -> RoutingStatus {
        switch kind {
        case .claude: return try claudeStatus(endpoint)
        case .codex: return try codexStatus(endpoint)
        }
    }

    private func claudeStatus(_ endpoint: ProxyEndpoint?) throws -> RoutingStatus {
        let settings = try readJSON(claudeSettings)
        let env = settings["env"] as? [String: Any] ?? [:]
        guard let base = env["ANTHROPIC_BASE_URL"] as? String else { return .absent }
        guard ClaudeRouting.isClaudexURL(base) else {
            return .foreign("ANTHROPIC_BASE_URL already points at \(base)")
        }
        if let endpoint, base == endpoint.baseURL(for: .claude).absoluteString,
           ClaudeRouting.token(in: env["ANTHROPIC_CUSTOM_HEADERS"] as? String) == endpoint.token {
            return .installed
        }
        return .stale(base)
    }

    private func codexStatus(_ endpoint: ProxyEndpoint?) throws -> RoutingStatus {
        let toml = try readText(codexConfig)
        let selected = TOMLEdit.topLevelValue("model_provider", in: toml)
        let block = TOMLEdit.managedBlock(in: toml)

        if let selected, selected != CodexRouting.providerKey {
            return .foreign("model_provider is set to \"\(selected)\"")
        }
        guard let block else {
            return selected == nil ? .absent : .foreign("model_provider selects claudex but its provider block is gone")
        }
        guard let base = TOMLEdit.value(of: "base_url", in: block) else {
            return .foreign("The claudex block in config.toml has been edited")
        }
        if let endpoint, base == endpoint.baseURL(for: .codex).absoluteString,
           TOMLEdit.value(of: "\"\(ProxyEndpoint.tokenHeader)\"", in: block) == endpoint.token {
            return .installed
        }
        return .stale(base)
    }

    // MARK: - Install

    public func install(_ endpoint: ProxyEndpoint, for kind: ProviderKind) throws {
        // Refusing on `foreign` is the whole point of checking. Overwriting a gateway someone
        // configured for work reasons is not a change claudex gets to make silently.
        if case .foreign(let reason) = try status(for: kind, endpoint: endpoint) {
            throw ClaudexError.unsupportedAccount("Not changing \(kind.displayName) configuration: \(reason)")
        }
        switch kind {
        case .claude: try installClaude(endpoint)
        case .codex: try installCodex(endpoint)
        }
    }

    private func installClaude(_ endpoint: ProxyEndpoint) throws {
        var settings = try readJSON(claudeSettings)
        var env = settings["env"] as? [String: Any] ?? [:]

        // Recorded once. Reinstalling after a port change must not overwrite the backup with
        // claudex's own previous URL, or uninstall would restore a dead proxy.
        try recordBackupIfNew(.claude, RoutingBackup(
            previousBaseURL: ClaudeRouting.isClaudexURL(env["ANTHROPIC_BASE_URL"] as? String ?? "")
                ? nil : env["ANTHROPIC_BASE_URL"] as? String,
            previousModelProvider: nil,
            installedAt: Date()
        ))

        env["ANTHROPIC_BASE_URL"] = endpoint.baseURL(for: .claude).absoluteString
        env["ANTHROPIC_CUSTOM_HEADERS"] = ClaudeRouting.headers(
            replacingTokenIn: env["ANTHROPIC_CUSTOM_HEADERS"] as? String,
            with: endpoint.token
        )
        // ANTHROPIC_AUTH_TOKEN is deliberately not set. Setting it moves Claude Code off its
        // claude.ai login, which is what carries connectors and MCP; the proxy is authenticated
        // by the custom header instead.
        settings["env"] = env

        try AtomicFile.backup(claudeSettings)
        try AtomicFile.write(try encodeJSON(settings), to: claudeSettings)
    }

    private func installCodex(_ endpoint: ProxyEndpoint) throws {
        let toml = try readText(codexConfig)

        try recordBackupIfNew(.codex, RoutingBackup(
            previousBaseURL: nil,
            previousModelProvider: TOMLEdit.topLevelValue("model_provider", in: toml),
            installedAt: Date()
        ))

        var updated = TOMLEdit.removingManagedBlock(from: toml)
        updated = TOMLEdit.settingTopLevel("model_provider", to: CodexRouting.providerKey, in: updated)
        updated += CodexRouting.block(endpoint)

        try AtomicFile.backup(codexConfig)
        try AtomicFile.write(Data(updated.utf8), to: codexConfig)
    }

    // MARK: - Uninstall

    public func uninstall(for kind: ProviderKind) throws {
        let backup = try loadBackups()[kind]
        switch kind {
        case .claude: try uninstallClaude(backup)
        case .codex: try uninstallCodex(backup)
        }
        var all = try loadBackups()
        all[kind] = nil
        try saveBackups(all)
    }

    private func uninstallClaude(_ backup: RoutingBackup?) throws {
        var settings = try readJSON(claudeSettings)
        guard var env = settings["env"] as? [String: Any] else { return }

        if let previous = backup?.previousBaseURL {
            env["ANTHROPIC_BASE_URL"] = previous
        } else {
            env["ANTHROPIC_BASE_URL"] = nil
        }
        // Only claudex's own line comes out. Anything else the user put in this variable is
        // theirs and survives.
        let remaining = ClaudeRouting.headers(removingTokenFrom: env["ANTHROPIC_CUSTOM_HEADERS"] as? String)
        env["ANTHROPIC_CUSTOM_HEADERS"] = remaining
        settings["env"] = env.isEmpty ? nil : env

        try AtomicFile.backup(claudeSettings)
        try AtomicFile.write(try encodeJSON(settings), to: claudeSettings)
    }

    private func uninstallCodex(_ backup: RoutingBackup?) throws {
        let toml = try readText(codexConfig)
        var updated = TOMLEdit.removingManagedBlock(from: toml)
        updated = TOMLEdit.settingTopLevel("model_provider", to: backup?.previousModelProvider, in: updated)

        try AtomicFile.backup(codexConfig)
        try AtomicFile.write(Data(updated.utf8), to: codexConfig)
    }

    // MARK: - Files

    private func readText(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudexError.decoding("\(url.lastPathComponent) is not a JSON object")
        }
        return object
    }

    private func encodeJSON(_ object: [String: Any]) throws -> Data {
        // Sorted and pretty because this file is read and edited by hand, and an unstable key
        // order would make every claudex write look like a large diff.
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func recordBackupIfNew(_ kind: ProviderKind, _ backup: RoutingBackup) throws {
        var all = try loadBackups()
        guard all[kind] == nil else { return }
        all[kind] = backup
        try saveBackups(all)
    }

    private func loadBackups() throws -> [ProviderKind: RoutingBackup] {
        guard let data = try? Data(contentsOf: backups) else { return [:] }
        return (try? JSONDecoder.claudex.decode([ProviderKind: RoutingBackup].self, from: data)) ?? [:]
    }

    private func saveBackups(_ all: [ProviderKind: RoutingBackup]) throws {
        try Paths.ensureSupportDirectory()
        try AtomicFile.write(try JSONEncoder.claudex.encode(all), to: backups)
    }
}
