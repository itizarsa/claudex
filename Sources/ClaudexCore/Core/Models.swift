import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// Who an account belongs to remotely. Purely descriptive: two accounts may carry the
/// same email and differ only by `remoteID`, which is why `Account.id` is local.
public struct Identity: Codable, Equatable, Sendable {
    public var email: String
    public var displayName: String?
    public var plan: String
    public var organization: String?
    /// The workspace the subscription lives in. One person can hold a personal Pro seat and
    /// a team seat under the same email and remote ID, and they are separate accounts here;
    /// the organisation is what tells them apart. Optional so older files still decode.
    public var organizationID: String?
    public var remoteID: String
}

public struct Account: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var provider: ProviderKind
    public var label: String
    /// One or two characters for the menu bar ring. Optional in storage so older files still
    /// decode; `badge` supplies the fallback.
    public var alias: String?
    public var identity: Identity
    public var enabled: Bool
    public var order: Int
    public var addedAt: Date

    /// What the ring shows. Two letters rather than one: a single initial collides as soon as
    /// two accounts share it, and "AR" reads as a name where "A" reads as a marker.
    public var badge: String {
        if let alias, !alias.isEmpty { return String(alias.prefix(2)).uppercased() }
        return String(label.prefix(2)).uppercased()
    }

    public init(
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
public struct UsageWindow: Codable, Equatable, Sendable {
    public var percent: Double?
    public var resetsAt: Date?
    /// Length of the window. Needed to place the time marker: without it, a reset time says
    /// nothing about how far through the window we are.
    public var windowSeconds: Double?

    public init(percent: Double?, resetsAt: Date?, windowSeconds: Double?) {
        self.percent = percent
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
    }

    public static let unknown = UsageWindow(percent: nil, resetsAt: nil, windowSeconds: nil)

    /// How far through the window the clock has travelled, 0 to 1. Compared against `fraction`
    /// this is the useful reading: usage ahead of the clock means burning faster than the
    /// window refills.
    public var elapsed: Double? {
        guard let resetsAt, let windowSeconds, windowSeconds > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSinceNow
        guard remaining > 0 else { return 1 }
        return min(1, max(0, 1 - remaining / windowSeconds))
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var fiveHour: UsageWindow
    public var weekly: UsageWindow
    public var fetchedAt: Date

    public init(fiveHour: UsageWindow, weekly: UsageWindow, fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fetchedAt = fetchedAt
    }

    public var isUsable: Bool { fiveHour.percent != nil || weekly.percent != nil }
}

public enum AccountState: Equatable, Sendable {
    case idle
    case loading
    case ok(UsageSnapshot)
    case failed(String)

    public var snapshot: UsageSnapshot? {
        if case .ok(let snapshot) = self { return snapshot }
        return nil
    }
}

// MARK: - Credentials

public struct ClaudeCredentials: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    /// Milliseconds since epoch, matching the on-disk format Claude Code writes.
    public var expiresAt: Int64
    public var refreshTokenExpiresAt: Int64?
    public var scopes: [String]
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public var expiryDate: Date { Date(timeIntervalSince1970: Double(expiresAt) / 1000) }
}

public struct CodexCredentials: Codable, Equatable, Sendable {
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String
    public var accountID: String
    public var lastRefresh: Date?
}

public enum Credentials: Codable, Equatable, Sendable {
    case claude(ClaudeCredentials)
    case codex(CodexCredentials)

    public var kind: ProviderKind {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    /// Stable fingerprint of the refresh token, used to recognise whether a stored account
    /// is the one the CLI currently holds without ever comparing secrets in the clear.
    public var refreshFingerprint: String {
        switch self {
        case .claude(let c): return Fingerprint.of(c.refreshToken)
        case .codex(let c): return Fingerprint.of(c.refreshToken)
        }
    }
}

public enum ClaudexError: LocalizedError {
    case http(Int, String)
    case decoding(String)
    case unsupportedAccount(String)
    case notSignedIn(ProviderKind)
    case keychain(OSStatus)

    public var errorDescription: String? {
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
