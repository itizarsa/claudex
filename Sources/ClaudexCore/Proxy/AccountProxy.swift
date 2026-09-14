import Foundation
import Hummingbird
import Logging
import NIOCore
import ServiceLifecycle

/// A local listener that routed CLIs send provider traffic to.
///
/// Two methods on purpose. Everything between them — caller authentication, body limits,
/// account selection, token refresh, header and body adaptation, streaming, retry, quota
/// observation and shutdown drain — is the module's business and none of it is safe to
/// orchestrate from outside, because the ordering is what makes it correct.
public protocol AccountProxy: Sendable {
    func start() async throws -> ProxyEndpoint
    func stop() async
}

public actor LoopbackAccountProxy: AccountProxy {
    public struct Limits: Sendable {
        /// Large enough for a long conversation with attachments, small enough that a local
        /// process cannot exhaust memory by claiming it is about to send one.
        public var maxRequestBytes: Int
        /// How long a normal shutdown waits for responses that are still streaming before it
        /// cuts them off.
        public var drain: Duration

        public init(maxRequestBytes: Int = 32 << 20, drain: Duration = .seconds(10)) {
            self.maxRequestBytes = maxRequestBytes
            self.drain = drain
        }
    }

    private let routing: any AccountRouting
    private let limits: Limits
    private let logger: Logger
    private var running: Running?

    private struct Running {
        let endpoint: ProxyEndpoint
        let group: ServiceGroup
        let task: Task<Void, Error>
    }

    public init(routing: any AccountRouting, limits: Limits = Limits(), logger: Logger = Logger(label: "claudex.proxy")) {
        self.routing = routing
        self.limits = limits
        self.logger = logger
    }

    /// Binds and returns once the port is known. Starting twice returns the running endpoint
    /// rather than a second listener: a caller that races itself should not end up with two
    /// ports, only one of which the CLIs were told about.
    public func start() async throws -> ProxyEndpoint {
        if let running { return running.endpoint }

        let token = ProxyEndpoint.newToken()
        let handler = ProxyHandler(routing: routing, client: UpstreamClient(), maxRequestBytes: limits.maxRequestBytes)

        let router = Router()
        router.middlewares.add(ProxyTokenMiddleware(token: token))
        for kind in ProviderKind.allCases {
            for method in [HTTPRequest.Method.get, .post] {
                router.on("/\(kind.rawValue)/**", method: method) { request, _ in
                    try await handler.handle(kind, request)
                }
            }
        }

        // Port 0 rather than a fixed one: a hardcoded port collides with whatever else the
        // user runs, and the CLIs are configured from the value this returns anyway.
        let (ports, portContinuation) = AsyncStream<Int>.makeStream()
        let application = Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: 0),
                serverName: nil
            ),
            onServerRunning: { channel in
                portContinuation.yield(channel.localAddress?.port ?? 0)
                portContinuation.finish()
            },
            logger: logger
        )

        // Empty signal set: the app owns when this stops. Letting the group also listen for
        // SIGTERM would give a menu bar app two shutdown paths that do not agree.
        let group = ServiceGroup(services: [application], gracefulShutdownSignals: [], logger: logger)
        let task = Task { try await group.run() }

        guard let port = await ports.first(where: { _ in true }), port != 0 else {
            task.cancel()
            throw ClaudexError.unsupportedAccount("Proxy could not bind a loopback port")
        }

        let endpoint = ProxyEndpoint(host: "127.0.0.1", port: port, token: token)
        running = Running(endpoint: endpoint, group: group, task: task)
        logger.info("proxy listening on \(endpoint.host):\(endpoint.port)")
        return endpoint
    }

    /// Stops accepting connections, lets in-flight responses finish, then cuts off what is
    /// left. A response already streaming to a CLI cannot be moved to another account or
    /// replayed, so the only kind thing to do with it is let it end.
    public func stop() async {
        guard let running else { return }
        self.running = nil

        await running.group.triggerGracefulShutdown()
        let deadline = Task {
            try await Task.sleep(for: limits.drain)
            running.task.cancel()
        }
        _ = try? await running.task.value
        deadline.cancel()
        logger.info("proxy stopped")
    }
}
