import Foundation

/// Turning one inbound CLI request into the upstream request that serves it.
///
/// Pure value transformation: no network, no credential lookup, no clock. That is deliberate.
/// The header allowlist and the Claude body rewrite are the two places where a mistake sends
/// the wrong account's identity to a provider, and both are worth testing without a socket.
enum UpstreamRequest {
    /// Headers that must not be copied onward.
    ///
    /// `Connection` and its relatives describe a single hop. `Content-Length`, `Host` and
    /// `Transfer-Encoding` are recomputed by the upstream client. The provider credential
    /// headers are dropped and reissued rather than passed through, so an inbound `x-api-key`
    /// from some other local process can never ride out on claudex's subscription.
    static let dropped: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade",
        "content-length", "host", "expect",
        "authorization", "x-api-key", "chatgpt-account-id",
        ProxyEndpoint.tokenHeader.lowercased(),
    ]

    /// Response headers the proxy does not echo back. The body is re-framed on the way out,
    /// so any length or encoding the backend declared describes a message we are no longer
    /// sending.
    static let droppedResponse: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "transfer-encoding", "upgrade",
        "content-length", "content-encoding",
    ]

    static func base(for kind: ProviderKind) -> URL {
        switch kind {
        case .claude: return Endpoints.Claude.inference
        case .codex: return Endpoints.Codex.inference
        }
    }

    /// The upstream URL for a request that arrived at `/<provider>/<tail>`. The tail is
    /// forwarded verbatim, including its query, because the proxy has no opinion about which
    /// provider routes exist and guessing would break the CLI on the next API addition.
    static func url(for kind: ProviderKind, tail: String, query: String?) -> URL? {
        let base = base(for: kind).absoluteString
        let path = tail.hasPrefix("/") ? tail : "/" + tail
        guard var components = URLComponents(string: base + path) else { return nil }
        components.percentEncodedQuery = query
        return components.url
    }

    /// The headers to send upstream: everything the CLI sent that is safe to relay, plus the
    /// selected account's credential.
    ///
    /// `inbound` keys are expected lowercased, which is how both HTTP/2 and `HTTPFields`
    /// present them.
    static func headers(
        for kind: ProviderKind,
        inbound: [String: String],
        account: RoutedAccount
    ) -> [String: String] {
        var headers = inbound.filter { !dropped.contains($0.key) }

        switch account.credentials {
        case .claude(let credential):
            headers["authorization"] = "Bearer \(credential.accessToken)"
            // Additive, not replacing: Claude Code sends feature betas the backend needs, and
            // the OAuth beta has to be present alongside them for a subscription token to be
            // accepted at all.
            headers["anthropic-beta"] = merged(headers["anthropic-beta"], Endpoints.Claude.betaHeader)
        case .codex(let credential):
            headers["authorization"] = "Bearer \(credential.accessToken)"
            headers["chatgpt-account-id"] = credential.accountID
        }

        headers["user-agent"] = inbound["user-agent"] ?? Endpoints.userAgent
        return headers
    }

    private static func merged(_ existing: String?, _ value: String) -> String {
        guard let existing, !existing.isEmpty else { return value }
        let parts = existing.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.contains(value) ? existing : existing + "," + value
    }

    /// The body to send upstream.
    ///
    /// Claude Code stamps the signed-in account's UUID into `metadata.user_id`. Left alone it
    /// describes whichever account the CLI last wrote to disk, not the one the proxy picked,
    /// and the backend reads it. Rewriting it is the difference between routing a request and
    /// mislabelling it.
    ///
    /// Codex bodies pass through untouched: their thread and session identifiers are the
    /// CLI's own conversation state and rewriting any of it would break resumption.
    static func body(for kind: ProviderKind, _ data: Data, account: RoutedAccount) -> Data {
        guard kind == .claude, !data.isEmpty else { return data }
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var metadata = object["metadata"] as? [String: Any],
              let userID = metadata["user_id"] as? String
        else { return data }

        let rewritten = rewriteAccountSegment(userID, to: account.identity.remoteID)
        guard rewritten != userID else { return data }
        metadata["user_id"] = rewritten
        object["metadata"] = metadata
        // A body we cannot re-encode is a body we forward unchanged. Failing the request over
        // a cosmetic field would be worse than sending the field we were given.
        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }

    /// Replaces the `account_<uuid>` run inside Claude Code's composite user id, leaving the
    /// user and session segments — which are the CLI's, not ours — exactly as they arrived.
    static func rewriteAccountSegment(_ userID: String, to remoteID: String) -> String {
        let segments = userID.split(separator: "_", omittingEmptySubsequences: false)
        guard let marker = segments.firstIndex(of: "account"), segments.index(after: marker) < segments.endIndex
        else { return userID }
        var rebuilt = segments.map(String.init)
        rebuilt[marker + 1] = remoteID
        return rebuilt.joined(separator: "_")
    }
}
