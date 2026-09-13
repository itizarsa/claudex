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
    /// Switch and exhaustion notices. Off silences the rotator without stopping it, so an
    /// automatic switch still happens; it just happens quietly.
    var notificationsEnabled: Bool = true
    /// Master switch for every Keychain call in the app. On, because claudex reaches the
    /// Keychain through `/usr/bin/security`, which is Apple-signed and so raises none of the
    /// authorisation prompts that in-process `SecItem` calls do from an ad-hoc signed build.
    /// Off falls back to a 0600 file in the app's container. See `Vault`.
    var allowKeychain: Bool = true

    static let `default` = Settings(
        thresholds: [.claude: .default, .codex: .default],
        activePollSeconds: 60,
        idlePollSeconds: 300,
        autoSwitchEnabled: false,
        showLabelInMenuBar: false,
        notificationsEnabled: true,
        allowKeychain: true
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
