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

    public static let `default` = Settings(
        thresholds: [.claude: .default, .codex: .default],
        activePollSeconds: 300,
        idlePollSeconds: 300,
        autoSwitchEnabled: false,
        showLabelInMenuBar: false,
        notificationsEnabled: true
    )

    public func thresholds(for kind: ProviderKind) -> ProviderThresholds {
        thresholds[kind] ?? .default
    }

    public static func load() -> Settings {
        guard let data = try? Data(contentsOf: Paths.settingsFile),
              var decoded = try? JSONDecoder.claudex.decode(Settings.self, from: data)
        else { return .default }
        // Older releases offered 30, 60 and 120 seconds. Keep those files valid while moving
        // them onto the request floor enforced by the polling scheduler.
        decoded.activePollSeconds = max(UsagePollScheduler.minimumInterval, decoded.activePollSeconds)
        decoded.idlePollSeconds = max(UsagePollScheduler.minimumInterval, decoded.idlePollSeconds)
        return decoded
    }

    public func save() {
        guard let data = try? JSONEncoder.claudex.encode(self) else { return }
        try? Paths.ensureSupportDirectory()
        try? AtomicFile.write(data, to: Paths.settingsFile)
    }
}
