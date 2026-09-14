import Foundation
import Testing
@testable import ClaudexCore

/// What the listener does before any provider is involved: where it binds, who it answers,
/// and whether it lets go of the port. None of these reach the network.
@Suite struct ProxyListenerTests {
    private func makeProxy() -> LoopbackAccountProxy {
        LoopbackAccountProxy(routing: StaticAccountRouting([:]))
    }

    private func status(_ url: URL, headers: [String: String] = [:]) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    @Test func bindsAnEphemeralLoopbackPort() async throws {
        let proxy = makeProxy()
        let endpoint = try await proxy.start()
        defer { Task { await proxy.stop() } }

        #expect(endpoint.host == "127.0.0.1")
        #expect(endpoint.port > 0)
        #expect(endpoint.token.isEmpty == false)
    }

    @Test func startingTwiceReusesOneListener() async throws {
        let proxy = makeProxy()
        let first = try await proxy.start()
        let second = try await proxy.start()
        defer { Task { await proxy.stop() } }

        // A second port would be a port no CLI was ever told about.
        #expect(first == second)
    }

    @Test func rejectsCallersWithoutTheToken() async throws {
        let proxy = makeProxy()
        let endpoint = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let url = endpoint.baseURL(for: .claude).appendingPathComponent("v1/messages")
        #expect(try await status(url) == 401)
        #expect(try await status(url, headers: [ProxyEndpoint.tokenHeader: "wrong"]) == 401)
    }

    @Test func isNotReachableOverIPv6Loopback() async throws {
        let proxy = makeProxy()
        let endpoint = try await proxy.start()
        defer { Task { await proxy.stop() } }

        // `.hostname("127.0.0.1")` must mean IPv4 only. If a future version also binds ::1,
        // the surface doubles silently, so the assumption is pinned here rather than in a
        // comment.
        let url = URL(string: "http://[::1]:\(endpoint.port)/claude/v1/messages")!
        await #expect(throws: (any Error).self) { try await status(url) }
    }

    @Test func releasesThePortOnStop() async throws {
        let proxy = makeProxy()
        let endpoint = try await proxy.start()
        await proxy.stop()

        let url = endpoint.baseURL(for: .claude).appendingPathComponent("v1/messages")
        await #expect(throws: (any Error).self) {
            try await status(url, headers: [ProxyEndpoint.tokenHeader: endpoint.token])
        }
    }
}
