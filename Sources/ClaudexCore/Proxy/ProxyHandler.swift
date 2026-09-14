import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// The request path, one request at a time.
///
/// Kept out of `LoopbackAccountProxy` because the proxy is an actor that owns the listener's
/// lifetime, and routing every request through that actor would serialise a server whose whole
/// job is to hold many streams open at once. Nothing here is shared mutable state.
struct ProxyHandler: Sendable {
    let routing: any AccountRouting
    let client: UpstreamClient
    /// Request bodies are read into memory before they are sent, so an attempt to replay a
    /// rejected request does not need the client to send it twice. That is only safe with a
    /// ceiling on it.
    let maxRequestBytes: Int

    func handle(_ kind: ProviderKind, _ request: Request) async throws -> Response {
        let body = try await collect(request)
        let tail = String(request.uri.path.dropFirst("/\(kind.rawValue)".count))
        let inbound = flatten(request.headers)

        var account = try await routing.resolve(kind)
        var upstream = try await send(kind, tail: tail, query: request.uri.query, method: request.method,
                                      inbound: inbound, body: body, account: account)

        // Requirement: refresh and retry once on 401, and only when the credential the
        // provider rejected is still the one on record. A late rejection of a token another
        // request already replaced says nothing about the credential we now hold.
        if upstream.status == 401, let refreshed = try await routing.refresh(kind, rejecting: account) {
            account = refreshed
            upstream = try await send(kind, tail: tail, query: request.uri.query, method: request.method,
                                      inbound: inbound, body: body, account: account)
        }

        await routing.observe(upstream.headers, from: account, kind: kind)
        return response(from: upstream)
    }

    private func collect(_ request: Request) async throws -> Data {
        var buffer = try await request.body.collect(upTo: maxRequestBytes)
        return buffer.readData(length: buffer.readableBytes) ?? Data()
    }

    private func send(
        _ kind: ProviderKind,
        tail: String,
        query: String?,
        method: HTTPRequest.Method,
        inbound: [String: String],
        body: Data,
        account: RoutedAccount
    ) async throws -> UpstreamResponse {
        guard let url = UpstreamRequest.url(for: kind, tail: tail, query: query) else {
            throw HTTPError(.badRequest, message: "Unroutable path")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body.isEmpty ? nil : UpstreamRequest.body(for: kind, body, account: account)
        for (key, value) in UpstreamRequest.headers(for: kind, inbound: inbound, account: account) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try await client.send(request)
    }

    /// The response head is copied through; the body is handed over as a sequence, never
    /// collected. A model response must reach the CLI as it is produced, not after it ends.
    private func response(from upstream: UpstreamResponse) -> Response {
        var headers = HTTPFields()
        for (key, value) in upstream.headers where !UpstreamRequest.droppedResponse.contains(key) {
            guard let name = HTTPField.Name(key) else { continue }
            headers[name] = value
        }
        return Response(
            status: .init(code: upstream.status),
            headers: headers,
            body: ResponseBody(asyncSequence: upstream.body)
        )
    }

    /// `HTTPFields` allows a name to repeat; `URLRequest` does not. Joining with a comma is
    /// what the field syntax means, and it is how `anthropic-beta` arrives in the first place.
    private func flatten(_ fields: HTTPFields) -> [String: String] {
        var flattened: [String: String] = [:]
        for field in fields {
            let key = field.name.canonicalName
            flattened[key] = flattened[key].map { $0 + "," + field.value } ?? field.value
        }
        return flattened
    }
}

/// Rejects any caller that cannot present the token claudex wrote into the CLI configuration.
///
/// Loopback binding says a request came from this machine. It does not say which process sent
/// it, and every other process on the machine would otherwise be able to spend the
/// subscription.
struct ProxyTokenMiddleware<Context: RequestContext>: RouterMiddleware {
    let token: String

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let presented = presentedToken(in: request), constantTimeEquals(presented, token) else {
            throw HTTPError(.unauthorized)
        }
        return try await next(request, context)
    }

    /// The custom header first. Claude Code keeps its own `Authorization` for the claude.ai
    /// login it must not be moved off, so the bearer form only exists for Codex, which has no
    /// competing use for it.
    private func presentedToken(in request: Request) -> String? {
        if let custom = request.headers[values: .init(ProxyEndpoint.tokenHeader)!].first { return custom }
        guard let authorization = request.headers[.authorization],
              authorization.lowercased().hasPrefix("bearer ")
        else { return nil }
        return String(authorization.dropFirst("bearer ".count))
    }

    /// Comparison time must not depend on how much of the token matched.
    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}
