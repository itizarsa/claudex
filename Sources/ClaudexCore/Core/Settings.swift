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
    /// Providers whose CLIs should route through Claudex. Defaults to both, including when
    /// decoding settings written before proxy-only routing existed.
    public var routedProviders: Set<ProviderKind>
    /// Switch and exhaustion notices. Off silences the rotator without stopping it, so an
    /// automatic switch still happens; it just happens quietly.
    public var notificationsEnabled: Bool = true

    public static let `default` = Settings(
        thresholds: [.claude: .default, .codex: .default],
        activePollSeconds: 300,
        idlePollSeconds: 300,
        autoSwitchEnabled: false,
        showLabelInMenuBar: false,
        routedProviders: Set(ProviderKind.allCases),
        notificationsEnabled: true
    )

    public init(
        thresholds: [ProviderKind: ProviderThresholds],
        activePollSeconds: Double,
        idlePollSeconds: Double,
        autoSwitchEnabled: Bool,
        showLabelInMenuBar: Bool,
        routedProviders: Set<ProviderKind>,
        notificationsEnabled: Bool
    ) {
        self.thresholds = thresholds
        self.activePollSeconds = activePollSeconds
        self.idlePollSeconds = idlePollSeconds
        self.autoSwitchEnabled = autoSwitchEnabled
        self.showLabelInMenuBar = showLabelInMenuBar
        self.routedProviders = routedProviders
        self.notificationsEnabled = notificationsEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case thresholds, activePollSeconds, idlePollSeconds, autoSwitchEnabled
        case showLabelInMenuBar, routedProviders, notificationsEnabled
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        thresholds = try values.decode([ProviderKind: ProviderThresholds].self, forKey: .thresholds)
        activePollSeconds = try values.decode(Double.self, forKey: .activePollSeconds)
        idlePollSeconds = try values.decode(Double.self, forKey: .idlePollSeconds)
        autoSwitchEnabled = try values.decode(Bool.self, forKey: .autoSwitchEnabled)
        showLabelInMenuBar = try values.decode(Bool.self, forKey: .showLabelInMenuBar)
        routedProviders = try values.decodeIfPresent(Set<ProviderKind>.self, forKey: .routedProviders)
            ?? Set(ProviderKind.allCases)
        notificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(thresholds, forKey: .thresholds)
        try values.encode(activePollSeconds, forKey: .activePollSeconds)
        try values.encode(idlePollSeconds, forKey: .idlePollSeconds)
        try values.encode(autoSwitchEnabled, forKey: .autoSwitchEnabled)
        try values.encode(showLabelInMenuBar, forKey: .showLabelInMenuBar)
        try values.encode(routedProviders, forKey: .routedProviders)
        try values.encode(notificationsEnabled, forKey: .notificationsEnabled)
    }

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
