import Foundation
import Testing
@testable import ClaudexCore

@Suite struct LocalUsageActivityTests {
    @Test func newestJSONLModificationWinsWithoutReadingContents() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let nested = root.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let older = nested.appending(path: "older.jsonl")
        let newer = nested.appending(path: "newer.jsonl")
        let ignored = nested.appending(path: "newer.txt")
        try Data("private conversation".utf8).write(to: older)
        try Data("not json".utf8).write(to: newer)
        try Data().write(to: ignored)

        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = first.addingTimeInterval(30)
        try FileManager.default.setAttributes([.modificationDate: first], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: second], ofItemAtPath: newer.path)
        try FileManager.default.setAttributes([.modificationDate: second.addingTimeInterval(30)], ofItemAtPath: ignored.path)

        let activity = LocalUsageActivity(roots: [.claude: root])
        #expect(activity.latestModificationDate(for: .claude) == second)
        #expect(activity.latestModificationDate(for: .codex) == nil)
    }
}

@Suite struct UsagePollSchedulerTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func candidate(
        _ id: UUID = UUID(),
        provider: ProviderKind = .claude,
        active: Bool,
        order: Int = 0,
        interval: TimeInterval = 300
    ) -> UsagePollCandidate {
        UsagePollCandidate(
            id: id,
            provider: provider,
            isActive: active,
            order: order,
            configuredInterval: interval
        )
    }

    @Test func activeAccountPollsInitiallyThenOnlyAfterNewActivityAndFloor() throws {
        let account = candidate(active: true)
        var scheduler = UsagePollScheduler()
        scheduler.start(accounts: [account], activity: [.claude: now], now: now)

        #expect(scheduler.nextDueAccount(from: [account], now: now)?.id == account.id)
        scheduler.didStart(account, at: now)
        scheduler.didSucceed(account)
        #expect(scheduler.nextDueAccount(from: [account], now: now.addingTimeInterval(600)) == nil)

        scheduler.observeActivity(for: .claude, at: now.addingTimeInterval(10))
        #expect(scheduler.nextDueAccount(from: [account], now: now.addingTimeInterval(299)) == nil)
        #expect(scheduler.nextDueAccount(from: [account], now: now.addingTimeInterval(300))?.id == account.id)
    }

    @Test func inactiveAccountsStartStaggeredAndRepeatFromTheirOwnAttempts() throws {
        let first = candidate(active: false, order: 0)
        let second = candidate(active: false, order: 1)
        var scheduler = UsagePollScheduler()
        scheduler.start(accounts: [first, second], activity: [:], now: now)

        #expect(scheduler.nextDueAccount(from: [first, second], now: now.addingTimeInterval(99)) == nil)
        #expect(scheduler.nextDueAccount(from: [first, second], now: now.addingTimeInterval(100))?.id == first.id)
        scheduler.didStart(first, at: now.addingTimeInterval(100))
        scheduler.didSucceed(first)
        #expect(scheduler.nextDueAccount(from: [first, second], now: now.addingTimeInterval(200))?.id == second.id)
        #expect(scheduler.nextDueAccount(from: [first], now: now.addingTimeInterval(399)) == nil)
        #expect(scheduler.nextDueAccount(from: [first], now: now.addingTimeInterval(400))?.id == first.id)
    }

    @Test func inactiveAccountsAreStaggeredAcrossProviders() throws {
        let claude = candidate(provider: .claude, active: false, order: 0)
        let codex = candidate(provider: .codex, active: false, order: 1)
        var scheduler = UsagePollScheduler()
        scheduler.start(accounts: [claude, codex], activity: [:], now: now)

        #expect(scheduler.nextDueAccount(from: [claude, codex], now: now.addingTimeInterval(99)) == nil)
        #expect(scheduler.nextDueAccount(from: [claude, codex], now: now.addingTimeInterval(100))?.id == claude.id)
        scheduler.didStart(claude, at: now.addingTimeInterval(100))
        scheduler.didSucceed(claude)
        #expect(scheduler.nextDueAccount(from: [claude, codex], now: now.addingTimeInterval(199)) == nil)
        #expect(scheduler.nextDueAccount(from: [claude, codex], now: now.addingTimeInterval(200))?.id == codex.id)
    }

    @Test func manualRefreshCannotBypassFloorOrBackoff() throws {
        let account = candidate(active: true, interval: 30)
        var scheduler = UsagePollScheduler()
        scheduler.start(accounts: [account], activity: [:], now: now)
        scheduler.didStart(account, at: now)
        scheduler.didFail(account, retryAt: now.addingTimeInterval(600))
        scheduler.requestRefresh([account.id])

        #expect(scheduler.nextDueAccount(from: [account], now: now.addingTimeInterval(300)) == nil)
        #expect(scheduler.nextDueAccount(from: [account], now: now.addingTimeInterval(600))?.id == account.id)
    }
}

@Suite struct UsageFailurePolicyTests {
    private let snapshot = UsageSnapshot(
        fiveHour: UsageWindow(percent: 20, resetsAt: nil, windowSeconds: 18_000),
        weekly: UsageWindow(percent: 30, resetsAt: nil, windowSeconds: 604_800),
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    @Test func retryableFailureKeepsExactSnapshot() {
        let current = AccountState.ok(snapshot)
        #expect(UsageFailurePolicy.state(after: ClaudexError.http(429, "busy"), current: current) == current)
        #expect(UsageFailurePolicy.state(after: ClaudexError.http(503, "down"), current: current) == current)
    }

    @Test func firstFailureStillAppearsWhenNoSnapshotExists() {
        #expect(UsageFailurePolicy.state(after: ClaudexError.http(429, "busy"), current: .loading) == .failed("HTTP 429: busy"))
    }

    @Test func rateLimitRefreshRunsOnceOnSecondConsecutiveResponse() {
        let id = UUID()
        var recovery = RateLimitRecovery()
        let first = recovery.shouldRefreshAfterRateLimit(for: id)
        let second = recovery.shouldRefreshAfterRateLimit(for: id)
        let third = recovery.shouldRefreshAfterRateLimit(for: id)
        #expect(!first)
        #expect(second)
        #expect(!third)
        recovery.reset(id)
        let afterReset = recovery.shouldRefreshAfterRateLimit(for: id)
        #expect(!afterReset)
    }
}
