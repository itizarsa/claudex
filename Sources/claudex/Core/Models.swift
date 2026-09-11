import Foundation

enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// Who an account belongs to remotely. Purely descriptive: two accounts may carry the
/// same email and differ only by `remoteID`, which is why `Account.id` is local.
struct Identity: Codable, Equatable, Sendable {
    var email: String
    var displayName: String?
    var plan: String
    var organization: String?
    var remoteID: String
}

struct Account: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var provider: ProviderKind
    var label: String
    /// One or two characters for the menu bar ring. Optional in storage so older files still
    /// decode; `badge` supplies the fallback.
    var alias: String?
    var identity: Identity
    var enabled: Bool
    var order: Int
    var addedAt: Date

    /// What the ring shows. Falls back to the first letter of the label.
    var badge: String {
        if let alias, !alias.isEmpty { return String(alias.prefix(2)).uppercased() }
        return String(label.prefix(1)).uppercased()
    }

    init(
        id: UUID = UUID(),
        provider: ProviderKind,
        label: String,
        alias: String? = nil,
        identity: Identity,
        enabled: Bool = true,
        order: Int = 0,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.alias = alias
        self.identity = identity
        self.enabled = enabled
        self.order = order
        self.addedAt = addedAt
    }
}

/// A single rate-limit window. `percent` is optional on purpose: a window the API did not
/// report is unknown, never zero. Treating a missing field as 0% would look like plenty of
/// headroom and drive a wrong rotation decision.
struct UsageWindow: Codable, Equatable, Sendable {
    var percent: Double?
    var resetsAt: Date?
    /// Length of the window. Needed to place the time marker: without it, a reset time says
    /// nothing about how far through the window we are.
    var windowSeconds: Double?

    static let unknown = UsageWindow(percent: nil, resetsAt: nil, windowSeconds: nil)

    /// How far through the window the clock has travelled, 0 to 1. Compared against `fraction`
    /// this is the useful reading: usage ahead of the clock means burning faster than the
    /// window refills.
    var elapsed: Double? {
        guard let resetsAt, let windowSeconds, windowSeconds > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSinceNow
        guard remaining > 0 else { return 1 }
        return min(1, max(0, 1 - remaining / windowSeconds))
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    var fiveHour: UsageWindow
    var weekly: UsageWindow
    var fetchedAt: Date

    var isUsable: Bool { fiveHour.percent != nil || weekly.percent != nil }
}

enum AccountState: Equatable, Sendable {
    case idle
    case loading
    case ok(UsageSnapshot)
    case failed(String)

    var snapshot: UsageSnapshot? {
        if case .ok(let snapshot) = self { return snapshot }
        return nil
    }
}

// MARK: - Credentials

struct ClaudeCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    /// Milliseconds since epoch, matching the on-disk format Claude Code writes.
    var expiresAt: Int64
    var refreshTokenExpiresAt: Int64?
    var scopes: [String]
    var subscriptionType: String?
    var rateLimitTier: String?

    var expiryDate: Date { Date(timeIntervalSince1970: Double(expiresAt) / 1000) }
}

struct CodexCredentials: Codable, Equatable, Sendable {
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var accountID: String
    var lastRefresh: Date?
}

enum Credentials: Codable, Equatable, Sendable {
    case claude(ClaudeCredentials)
    case codex(CodexCredentials)

    var kind: ProviderKind {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    /// Stable fingerprint of the refresh token, used to recognise whether a stored account
    /// is the one the CLI currently holds without ever comparing secrets in the clear.
    var refreshFingerprint: String {
        switch self {
        case .claude(let c): return Fingerprint.of(c.refreshToken)
        case .codex(let c): return Fingerprint.of(c.refreshToken)
        }
    }
}

enum ClaudexError: LocalizedError {
    case http(Int, String)
    case decoding(String)
    case unsupportedAccount(String)
    case notSignedIn(ProviderKind)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            return "HTTP \(code): \(body.prefix(160))"
        case .decoding(let detail):
            return "Unexpected response shape: \(detail)"
        case .unsupportedAccount(let reason):
            return reason
        case .notSignedIn(let kind):
            return "\(kind.displayName) CLI is not signed in"
        case .keychain(let status):
            return "Keychain error \(status)"
        }
    }
}
