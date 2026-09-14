import Foundation
import Testing
@testable import ClaudexCore

/// Install and uninstall against throwaway files. The property that matters throughout is that
/// a config claudex touched and then released is the config it found.
@Suite struct RoutingInstallerTests {
    private let endpoint = ProxyEndpoint(host: "127.0.0.1", port: 51234, token: "test-token")
    private let moved = ProxyEndpoint(host: "127.0.0.1", port: 62345, token: "second-token")

    private final class Sandbox {
        let root: URL
        let claude: URL
        let codex: URL
        let installer: NativeCLIRoutingInstaller

        init(claudeSettings: String?, codexConfig: String?) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "claudex-routing-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            claude = root.appending(path: "settings.json")
            codex = root.appending(path: "config.toml")
            if let claudeSettings { try Data(claudeSettings.utf8).write(to: claude) }
            if let codexConfig { try Data(codexConfig.utf8).write(to: codex) }
            installer = NativeCLIRoutingInstaller(
                claudeSettings: claude,
                codexConfig: codex,
                backups: root.appending(path: "routing.json")
            )
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func claudeJSON() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: claude)) as? [String: Any] ?? [:]
        }

        func claudeEnv() throws -> [String: String] {
            try claudeJSON()["env"] as? [String: String] ?? [:]
        }

        func codexText() throws -> String {
            String(decoding: try Data(contentsOf: codex), as: UTF8.self)
        }
    }

    // MARK: - Claude

    private let existingSettings = """
    {"env":{"CLAUDE_CODE_DISABLE_1M_CONTEXT":"1"},"permissions":{"defaultMode":"auto"}}
    """

    @Test func claudeInstallPointsAtTheProxyAndCarriesTheToken() throws {
        let sandbox = try Sandbox(claudeSettings: existingSettings, codexConfig: nil)
        try sandbox.installer.install(endpoint, for: .claude)

        let env = try sandbox.claudeEnv()
        #expect(env["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:51234/claude")
        #expect(env["ANTHROPIC_CUSTOM_HEADERS"] == "X-Claudex-Token: test-token")
    }

    @Test func claudeInstallNeverSetsAnAuthToken() throws {
        // Setting it moves Claude Code off its claude.ai login and takes connectors and MCP
        // with it, which is a far larger change than routing.
        let sandbox = try Sandbox(claudeSettings: existingSettings, codexConfig: nil)
        try sandbox.installer.install(endpoint, for: .claude)
        #expect(try sandbox.claudeEnv()["ANTHROPIC_AUTH_TOKEN"] == nil)
    }

    @Test func claudeInstallLeavesUnrelatedSettingsAlone() throws {
        let sandbox = try Sandbox(claudeSettings: existingSettings, codexConfig: nil)
        try sandbox.installer.install(endpoint, for: .claude)

        #expect(try sandbox.claudeEnv()["CLAUDE_CODE_DISABLE_1M_CONTEXT"] == "1")
        let permissions = try sandbox.claudeJSON()["permissions"] as? [String: Any]
        #expect(permissions?["defaultMode"] as? String == "auto")
    }

    @Test func claudeUninstallRestoresWhatWasThere() throws {
        let sandbox = try Sandbox(claudeSettings: existingSettings, codexConfig: nil)
        try sandbox.installer.install(endpoint, for: .claude)
        try sandbox.installer.uninstall(for: .claude)

        let env = try sandbox.claudeEnv()
        #expect(env["ANTHROPIC_BASE_URL"] == nil)
        #expect(env["ANTHROPIC_CUSTOM_HEADERS"] == nil)
        #expect(env["CLAUDE_CODE_DISABLE_1M_CONTEXT"] == "1")
        #expect(try sandbox.installer.status(for: .claude, endpoint: endpoint) == .absent)
    }

    @Test func claudeUninstallKeepsTheUsersOwnCustomHeaders() throws {
        let settings = #"{"env":{"ANTHROPIC_CUSTOM_HEADERS":"X-Org-Route: prod"}}"#
        let sandbox = try Sandbox(claudeSettings: settings, codexConfig: nil)
        try sandbox.installer.install(endpoint, for: .claude)

        let installed = try sandbox.claudeEnv()["ANTHROPIC_CUSTOM_HEADERS"]
        #expect(installed?.contains("X-Org-Route: prod") == true)
        #expect(installed?.contains("X-Claudex-Token: test-token") == true)

        try sandbox.installer.uninstall(for: .claude)
        #expect(try sandbox.claudeEnv()["ANTHROPIC_CUSTOM_HEADERS"] == "X-Org-Route: prod")
    }

    @Test func claudeRefusesToRepointSomeoneElsesGateway() throws {
        let settings = #"{"env":{"ANTHROPIC_BASE_URL":"https://llm-gateway.example.com"}}"#
        let sandbox = try Sandbox(claudeSettings: settings, codexConfig: nil)

        guard case .foreign = try sandbox.installer.status(for: .claude, endpoint: endpoint) else {
            Issue.record("An organisation gateway must not read as claudex routing")
            return
        }
        #expect(throws: (any Error).self) { try sandbox.installer.install(endpoint, for: .claude) }
        #expect(try sandbox.claudeEnv()["ANTHROPIC_BASE_URL"] == "https://llm-gateway.example.com")
    }

    @Test func claudeReportsStaleAfterThePortMoves() throws {
        let sandbox = try Sandbox(claudeSettings: existingSettings, codexConfig: nil)
        try sandbox.installer.install(endpoint, for: .claude)

        // The port is ephemeral, so this is the state every relaunch starts in.
        #expect(try sandbox.installer.status(for: .claude, endpoint: moved) == .stale("http://127.0.0.1:51234/claude"))
        try sandbox.installer.install(moved, for: .claude)
        #expect(try sandbox.installer.status(for: .claude, endpoint: moved) == .installed)
    }

    // MARK: - Codex

    private let existingConfig = """
    model = "gpt-5.6-sol"
    approval_policy = "on-request"

    [features]
    hooks = true

    [mcp_servers.example]
    command = "example"

    """

    @Test func codexInstallSelectsAndDefinesTheProvider() throws {
        let sandbox = try Sandbox(claudeSettings: nil, codexConfig: existingConfig)
        try sandbox.installer.install(endpoint, for: .codex)

        let toml = try sandbox.codexText()
        #expect(toml.contains(#"model_provider = "claudex""#))
        #expect(toml.contains("[model_providers.claudex]"))
        #expect(toml.contains(#"base_url = "http://127.0.0.1:51234/codex""#))
        #expect(toml.contains(#"wire_api = "responses""#))
        #expect(toml.contains(#""X-Claudex-Token" = "test-token""#))
    }

    @Test func codexKeepsTheSelectionAboveTheFirstTable() throws {
        let sandbox = try Sandbox(claudeSettings: nil, codexConfig: existingConfig)
        try sandbox.installer.install(endpoint, for: .codex)

        let lines = try sandbox.codexText().components(separatedBy: "\n")
        let selection = lines.firstIndex { $0.hasPrefix("model_provider =") }
        let firstTable = lines.firstIndex { $0.hasPrefix("[") }
        // Below a table header the key would become a member of that table, not a setting.
        #expect(selection != nil && firstTable != nil && selection! < firstTable!)
    }

    @Test func codexInstallLeavesUnrelatedTablesAlone() throws {
        let sandbox = try Sandbox(claudeSettings: nil, codexConfig: existingConfig)
        try sandbox.installer.install(endpoint, for: .codex)

        let toml = try sandbox.codexText()
        #expect(toml.contains(#"model = "gpt-5.6-sol""#))
        #expect(toml.contains("[features]"))
        #expect(toml.contains("[mcp_servers.example]"))
    }

    @Test func codexUninstallRestoresTheOriginalFile() throws {
        let sandbox = try Sandbox(claudeSettings: nil, codexConfig: existingConfig)
        try sandbox.installer.install(endpoint, for: .codex)
        try sandbox.installer.uninstall(for: .codex)

        #expect(try sandbox.codexText() == existingConfig)
        #expect(try sandbox.installer.status(for: .codex, endpoint: endpoint) == .absent)
    }

    @Test func codexReinstallReplacesTheBlockRatherThanRepeatingIt() throws {
        let sandbox = try Sandbox(claudeSettings: nil, codexConfig: existingConfig)
        try sandbox.installer.install(endpoint, for: .codex)
        try sandbox.installer.install(moved, for: .codex)

        let toml = try sandbox.codexText()
        #expect(toml.components(separatedBy: "[model_providers.claudex]").count == 2)
        #expect(toml.contains("62345"))
        #expect(toml.contains("51234") == false)

        // And the file still returns to where it started, so a repaired port does not leak
        // into the restore.
        try sandbox.installer.uninstall(for: .codex)
        #expect(try sandbox.codexText() == existingConfig)
    }

    @Test func codexRestoresAPreviouslySelectedProvider() throws {
        let config = """
        model_provider = "ollama"
        model = "llama"

        [model_providers.ollama]
        name = "Ollama"

        """
        let sandbox = try Sandbox(claudeSettings: nil, codexConfig: config)
        // A provider the user chose is a decision claudex does not overrule.
        guard case .foreign = try sandbox.installer.status(for: .codex, endpoint: endpoint) else {
            Issue.record("A user-selected model_provider must not read as installable")
            return
        }
        #expect(throws: (any Error).self) { try sandbox.installer.install(endpoint, for: .codex) }
        #expect(try sandbox.codexText() == config)
    }

    @Test func codexDetectsAHandEditedBlock() throws {
        let sandbox = try Sandbox(claudeSettings: nil, codexConfig: existingConfig)
        try sandbox.installer.install(endpoint, for: .codex)

        let tampered = try sandbox.codexText().replacingOccurrences(of: "base_url", with: "base_urrl")
        try Data(tampered.utf8).write(to: sandbox.codex)

        guard case .foreign = try sandbox.installer.status(for: .codex, endpoint: endpoint) else {
            Issue.record("An edited managed block must not be silently overwritten")
            return
        }
    }

    @Test func codexInstallsIntoAnEmptyConfig() throws {
        let sandbox = try Sandbox(claudeSettings: nil, codexConfig: nil)
        #expect(try sandbox.installer.status(for: .codex, endpoint: endpoint) == .absent)
        try sandbox.installer.install(endpoint, for: .codex)
        #expect(try sandbox.installer.status(for: .codex, endpoint: endpoint) == .installed)
    }
}
