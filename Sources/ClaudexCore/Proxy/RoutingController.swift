import Foundation
import Observation

/// Owns the pair that only makes sense together: the proxy, and the CLI configuration pointing
/// at it. Neither is useful alone — a listener nobody is configured to call does nothing, and a
/// configuration pointing at a dead port breaks the CLI outright — so turning routing on or off
/// is one action here rather than two the user has to sequence.
@MainActor
@Observable
public final class RoutingController {
    public enum State: Equatable, Sendable {
        case off
        case on
        /// Configured for claudex but not for this run. The port is ephemeral, so this is what
        /// every relaunch finds.
        case needsRepair(String)
        /// Someone else's routing. Claudex will not touch it.
        case blocked(String)
        case failed(String)
    }

    private let proxy: any AccountProxy
    private let installer: any CLIRoutingInstaller

    public private(set) var states: [ProviderKind: State] = [:]
    public private(set) var endpoint: ProxyEndpoint?
    /// The provider whose install or uninstall is in flight; the UI disables its control while
    /// set, because a half-applied config edit is the one state with no good recovery.
    public private(set) var busy: ProviderKind?

    public init(proxy: any AccountProxy, installer: any CLIRoutingInstaller) {
        self.proxy = proxy
        self.installer = installer
        refresh()
    }

    public func state(for kind: ProviderKind) -> State { states[kind] ?? .off }

    public var isRoutingAnything: Bool {
        ProviderKind.allCases.contains { state(for: $0) == .on }
    }

    /// Reads both files. Cheap, and the only way to notice an edit made outside claudex.
    public func refresh() {
        for kind in ProviderKind.allCases {
            states[kind] = read(kind)
        }
    }

    private func read(_ kind: ProviderKind) -> State {
        do {
            switch try installer.status(for: kind, endpoint: endpoint) {
            case .absent: return .off
            case .installed: return .on
            case .stale(let where_): return .needsRepair(where_)
            case .foreign(let reason): return .blocked(reason)
            }
        } catch {
            return .failed(ErrorPresenter.message(error))
        }
    }

    /// Starts the proxy if it is not up, then writes the CLI configuration.
    public func enable(_ kind: ProviderKind) async {
        guard busy == nil else { return }
        busy = kind
        defer { busy = nil }
        do {
            let endpoint = try await ensureProxy()
            try installer.install(endpoint, for: kind)
        } catch {
            states[kind] = .failed(ErrorPresenter.message(error))
            return
        }
        refresh()
    }

    /// Restores the CLI configuration, and stops the proxy once nothing is pointed at it.
    public func disable(_ kind: ProviderKind) async {
        guard busy == nil else { return }
        busy = kind
        defer { busy = nil }
        do {
            try installer.uninstall(for: kind)
        } catch {
            states[kind] = .failed(ErrorPresenter.message(error))
            return
        }
        refresh()
        if !isRoutingAnything {
            await proxy.stop()
            endpoint = nil
        }
    }

    /// Applies the persisted routing preference at launch. Proxy-only switching defaults both
    /// providers on, so a fresh install writes routing after the app first opens. A foreign
    /// gateway remains untouched.
    public func configureOnLaunch(enabledProviders: Set<ProviderKind>) async {
        refresh()
        for kind in ProviderKind.allCases {
            let state = state(for: kind)
            if enabledProviders.contains(kind) {
                switch state {
                case .on, .blocked: break
                case .off, .needsRepair, .failed: await enable(kind)
                }
            } else {
                switch state {
                case .on, .needsRepair: await disable(kind)
                case .off, .blocked, .failed: break
                }
            }
        }
    }

    /// Normal termination. Leaves the configuration in place — the launch repair puts the new
    /// port in — and only drains the listener.
    public func shutdown() async {
        await proxy.stop()
        endpoint = nil
    }

    private func ensureProxy() async throws -> ProxyEndpoint {
        if let endpoint { return endpoint }
        let started = try await proxy.start()
        endpoint = started
        return started
    }
}
