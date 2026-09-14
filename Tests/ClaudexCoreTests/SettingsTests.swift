import Foundation
import Testing
@testable import ClaudexCore

@Suite struct SettingsTests {
    @Test func settingsFromBeforeProxyOnlyModeEnableBothRoutes() throws {
        let encoded = try JSONEncoder.claudex.encode(Settings.default)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["routedProviders"] = nil

        let legacy = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder.claudex.decode(Settings.self, from: legacy)

        #expect(decoded.routedProviders == Set(ProviderKind.allCases))
    }

    @Test func disabledRoutesRoundTrip() throws {
        var settings = Settings.default
        settings.routedProviders = [.claude]

        let encoded = try JSONEncoder.claudex.encode(settings)
        let decoded = try JSONDecoder.claudex.decode(Settings.self, from: encoded)

        #expect(decoded.routedProviders == [.claude])
    }
}
