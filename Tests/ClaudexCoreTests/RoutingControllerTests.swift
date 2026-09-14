import Foundation
import Testing
@testable import ClaudexCore

private actor RecordingProxy: AccountProxy {
    let endpoint = ProxyEndpoint(host: "127.0.0.1", port: 51234, token: "test-token")
    private(set) var starts = 0

    func start() async throws -> ProxyEndpoint {
        starts += 1
        return endpoint
    }

    func stop() async {}
}

private final class RecordingRoutingInstaller: CLIRoutingInstaller, @unchecked Sendable {
    private let lock = NSLock()
    private var installed: Set<ProviderKind> = []

    func status(for kind: ProviderKind, endpoint: ProxyEndpoint?) throws -> RoutingStatus {
        lock.withLock { installed.contains(kind) ? .installed : .absent }
    }

    func install(_ endpoint: ProxyEndpoint, for kind: ProviderKind) throws {
        lock.withLock { _ = installed.insert(kind) }
    }

    func uninstall(for kind: ProviderKind) throws {
        lock.withLock { _ = installed.remove(kind) }
    }

    var installedProviders: Set<ProviderKind> {
        lock.withLock { installed }
    }
}

@MainActor
@Suite struct RoutingControllerTests {
    @Test func firstLaunchInstallsRoutingForEveryProvider() async {
        let proxy = RecordingProxy()
        let installer = RecordingRoutingInstaller()
        let controller = RoutingController(proxy: proxy, installer: installer)

        await controller.configureOnLaunch(enabledProviders: Set(ProviderKind.allCases))

        #expect(installer.installedProviders == Set(ProviderKind.allCases))
        #expect(await proxy.starts == 1)
        for kind in ProviderKind.allCases {
            #expect(controller.state(for: kind) == .on)
        }
    }

    @Test func launchHonorsDisabledProviderPreference() async {
        let proxy = RecordingProxy()
        let installer = RecordingRoutingInstaller()
        let controller = RoutingController(proxy: proxy, installer: installer)

        await controller.configureOnLaunch(enabledProviders: [.claude])

        #expect(installer.installedProviders == [.claude])
        #expect(controller.state(for: .claude) == .on)
        #expect(controller.state(for: .codex) == .off)
    }
}
