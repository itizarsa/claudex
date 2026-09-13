import Foundation

public struct ProviderThresholds: Codable, Equatable, Sendable {
    public var fiveHour: Double
    public var weekly: Double

    public static let `default` = ProviderThresholds(fiveHour: 85, weekly: 90)
}

public struct Settings: Codable, Equatable, Sendable {
    public var thresholds: [ProviderKind: ProviderThresholds]
    public var activePollSeconds: Double
    public var idlePollSeconds: Double
    public var autoSwitchEnabled: Bool
    public var showLabelInMenuBar: Bool
    /// Switch and exhaustion notices. Off silences the rotator without stopping it, so an
    /// automatic switch still happens; it just happens quietly.
    public var notificationsEnabled: Bool = true
    /// Master switch for every Keychain call in the app. On, because claudex reaches the
    /// Keychain through `/usr/bin/security`, which is Apple-signed and so raises none of the
    /// authorisation prompts that in-process `SecItem` calls do from an ad-hoc signed build.
    /// Off falls back to a 0600 file in the app's container. See `Vault`.
    public var allowKeychain: Bool = true

    public static let `default` = Settings(
        thresholds: [.claude: .default, .codex: .default],
        activePollSeconds: 60,
        idlePollSeconds: 300,
        autoSwitchEnabled: false,
        showLabelInMenuBar: false,
        notificationsEnabled: true,
        allowKeychain: true
    )

    public func thresholds(for kind: ProviderKind) -> ProviderThresholds {
        thresholds[kind] ?? .default
    }

    public static func load() -> Settings {
        guard let data = try? Data(contentsOf: Paths.settingsFile),
              let decoded = try? JSONDecoder.claudex.decode(Settings.self, from: data)
        else { return .default }
        return decoded
    }

    public func save() {
        guard let data = try? JSONEncoder.claudex.encode(self) else { return }
        try? Paths.ensureSupportDirectory()
        try? AtomicFile.write(data, to: Paths.settingsFile)
    }
}
