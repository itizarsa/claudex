import Foundation

/// A single rate-limit window. `percent` is optional on purpose: a window the API did not
/// report is unknown, never zero. Treating a missing field as 0% would look like plenty of
/// headroom.
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

public enum ClaudexError: LocalizedError {
    case decoding(String)
    case cliproxy(String)

    public var errorDescription: String? {
        switch self {
        case .decoding(let detail):
            return "Unexpected CLIProxyAPI output: \(detail)"
        case .cliproxy(let message):
            return message
        }
    }
}
