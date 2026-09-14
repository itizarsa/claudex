import Foundation

/// Where a routed CLI sends its provider traffic, and the token that proves the caller is one
/// of the CLIs claudex configured.
///
/// The token is not a provider secret — it never leaves the machine and no backend ever sees
/// it — but it is the only thing between claudex's subscriptions and every other process on
/// the box. Loopback binding limits who can reach the port; it establishes no identity, which
/// is the gap this closes.
public struct ProxyEndpoint: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let token: String

    public init(host: String, port: Int, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }

    /// The base URL one CLI is pointed at. The first path component selects the backend, so
    /// the listener can tell a Claude request from a Codex one without inspecting the body.
    public func baseURL(for kind: ProviderKind) -> URL {
        URL(string: "http://\(host):\(port)/\(kind.rawValue)")!
    }

    /// The header a routed CLI carries the token in. A custom header rather than
    /// `Authorization`, because Claude Code must keep sending its own claude.ai bearer:
    /// replacing it moves the CLI off the subscription login path and takes connectors and
    /// MCP with it.
    public static let tokenHeader = "X-Claudex-Token"

    /// 256 bits from the system generator, regenerated every run. Nothing persists it, so a
    /// stale value in a CLI config fails closed rather than granting access to a later run.
    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
    }
}
