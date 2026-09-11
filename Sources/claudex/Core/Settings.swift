import Foundation

struct ProviderThresholds: Codable, Equatable, Sendable {
    var fiveHour: Double
    var weekly: Double

    static let `default` = ProviderThresholds(fiveHour: 85, weekly: 90)
}

struct Settings: Codable, Equatable, Sendable {
    var thresholds: [ProviderKind: ProviderThresholds]
    var activePollSeconds: Double
    var idlePollSeconds: Double
    var autoSwitchEnabled: Bool
    var showLabelInMenuBar: Bool
    /// Menu bar percentage follows this provider. The popover always shows both.
    var menuBarProvider: ProviderKind
    /// Master switch for every Keychain call in the app, default off. An ad-hoc signed build
    /// gets a new code signature on each rebuild, so macOS treats it as a new application and
    /// blocks on an authorisation prompt that a background poll cannot answer. Turn this on
    /// only once the app is signed with a stable identity. See `Vault`.
    var allowKeychain: Bool = false

    static let `default` = Settings(
        thresholds: [.claude: .default, .codex: .default],
        activePollSeconds: 60,
        idlePollSeconds: 300,
        autoSwitchEnabled: false,
        showLabelInMenuBar: false,
        menuBarProvider: .claude,
        allowKeychain: false
    )

    func thresholds(for kind: ProviderKind) -> ProviderThresholds {
        thresholds[kind] ?? .default
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: Paths.settingsFile),
              let decoded = try? JSONDecoder.claudex.decode(Settings.self, from: data)
        else { return .default }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder.claudex.encode(self) else { return }
        try? Paths.ensureSupportDirectory()
        try? AtomicFile.write(data, to: Paths.settingsFile)
    }
}
