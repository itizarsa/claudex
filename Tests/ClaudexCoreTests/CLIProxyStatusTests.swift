import Foundation
import Testing
@testable import ClaudexCore

@Suite struct CLIProxyStatusTests {
    private func parse(_ json: String) throws -> [UsageAccount] {
        try CLIProxy.parse(Data(json.utf8))
    }

    @Test func mapsAccountsAndWindows() throws {
        let accounts = try parse("""
        {"files": [
          {"name": "a.json", "auth_index": "1", "provider": "claude", "email": "ann@example.com", "status": "active",
           "quota": {"observed_at": "2026-10-04T10:06:21.564+05:30", "signals": {
             "Anthropic-Ratelimit-Unified-5h-Utilization": "0.04", "Anthropic-Ratelimit-Unified-5h-Reset": "1793048400",
             "Anthropic-Ratelimit-Unified-7d-Utilization": "0.82", "Anthropic-Ratelimit-Unified-7d-Reset": "1793466000"}}},
          {"name": "b.json", "auth_index": "2", "provider": "claude", "email": "bob@example.com", "status": "active",
           "quota": {"observed_at": "2026-10-04T09:00:00+05:30", "signals": {
             "Anthropic-Ratelimit-Unified-5h-Utilization": "0.12"}}}
        ]}
        """)

        #expect(accounts.map(\.id) == ["a.json", "b.json"])
        #expect(accounts[0].health == "ready")
        #expect(accounts[0].snapshot?.fiveHour.percent == 4)
        #expect(accounts[0].snapshot?.weekly.percent == 82)
        #expect(accounts[0].snapshot?.fiveHour.resetsAt == Date(timeIntervalSince1970: 1793048400))
        #expect(accounts[1].snapshot?.fiveHour.percent == 12)
        #expect(accounts[1].snapshot?.weekly == .unknown)
    }

    @Test func skipsOtherProvidersAndDisabledAccounts() throws {
        let accounts = try parse("""
        {"files": [
          {"name": "c.json", "auth_index": "1", "provider": "codex", "email": "c@example.com"},
          {"name": "d.json", "auth_index": "2", "provider": "claude", "email": "d@example.com", "disabled": true}
        ]}
        """)
        #expect(accounts.isEmpty)
    }

    @Test func unavailableAccountReportsItsStatus() throws {
        let accounts = try parse("""
        {"files": [
          {"name": "a.json", "auth_index": "1", "provider": "claude", "email": "a@example.com",
           "status": "error", "status_message": "token expired"}
        ]}
        """)
        #expect(accounts[0].health == "token expired")
        #expect(accounts[0].snapshot == nil)
        #expect(!accounts[0].isActive)
    }

    @Test func quotaCooldownReadsAsRateLimited() throws {
        let accounts = try parse(#"""
        {"files": [
          {"name": "a.json", "auth_index": "1", "provider": "claude", "email": "a@example.com", "status": "error",
           "unavailable": true, "status_message": "{\"type\":\"error\"}",
           "cooldowns": [{"scope": "credential", "reason": "credential_quota"}]},
          {"name": "b.json", "auth_index": "2", "provider": "claude", "email": "b@example.com", "status": "error",
           "status_message": "{\"type\":\"error\",\"error\":{\"message\":\"Overloaded\"}}"}
        ]}
        """#)
        #expect(accounts[0].status == .exhausted)
        #expect(accounts[1].status == .unavailable("Overloaded"))
    }

    @Test func rejectsOutputWithoutFiles() {
        #expect(throws: ClaudexError.self) { try parse("{}") }
    }

    @Test func personalOrganisationIsPersonalOthersTeam() {
        #expect(CLIProxy.plan(organization: "Ann@Example.com's Organization", email: "ann@example.com") == "Personal")
        #expect(CLIProxy.plan(organization: "Superfans", email: "ann@example.com") == "Team")
        #expect(CLIProxy.plan(organization: nil, email: "ann@example.com") == "")
    }

    @Test func parsesFetchedQuota() throws {
        let json = try JSONView.parse(Data("""
        {"groups": [{"displayName": "Claude", "buckets": [
          {"window": "5h", "remainingFraction": 0.75, "resetTime": "2026-10-27T09:40:00Z"},
          {"window": "7d", "remainingFraction": 0}]}]}
        """.utf8))
        let snapshot = CLIProxy.parseQuota(json)
        #expect(snapshot.fiveHour.percent == 25)
        #expect(snapshot.fiveHour.resetsAt != nil)
        #expect(snapshot.weekly.percent == 100)
    }

    @Test func marksSoonestWeeklyResetAmongUsableAccounts() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func account(_ id: String, week: Double?, resetIn: Double, fiveHour: Double = 10, health: String = "ready") -> UsageAccount {
            let weekly = week.map { UsageWindow(percent: $0, resetsAt: now + resetIn, windowSeconds: nil) } ?? .unknown
            return UsageAccount(
                id: id, authIndex: id, email: id, health: health,
                snapshot: UsageSnapshot(
                    fiveHour: UsageWindow(percent: fiveHour, resetsAt: now + 3600, windowSeconds: nil),
                    weekly: weekly, fetchedAt: now))
        }
        func active(_ accounts: [UsageAccount]) -> String? {
            var accounts = accounts
            CLIProxy.markActive(&accounts, now: now)
            return accounts.first(where: \.isActive)?.id
        }

        #expect(active([account("late", week: 20, resetIn: 9000), account("soon", week: 50, resetIn: 100)]) == "soon")
        #expect(active([account("spent", week: 99, resetIn: 100), account("late", week: 20, resetIn: 9000)]) == "late")
        #expect(active([account("capped", week: 50, resetIn: 100, fiveHour: 100), account("late", week: 20, resetIn: 9000)]) == "late")
        #expect(active([account("down", week: 50, resetIn: 100, health: "expired"), account("unknown", week: nil, resetIn: 0)]) == "unknown")
        #expect(active([account("down", week: 50, resetIn: 100, health: "expired")]) == nil)
    }
}
