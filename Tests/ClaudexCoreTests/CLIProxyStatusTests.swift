import Foundation
import Testing
@testable import ClaudexCore

@Suite struct CLIProxyStatusTests {
    private func parse(_ json: String) throws -> [UsageAccount] {
        try CLIProxy.parse(Data(json.utf8))
    }

    @Test func mapsAccountsWindowsAndLastServed() throws {
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
        #expect(accounts[0].authIndex == "1")
        #expect(accounts[0].isActive)
        #expect(accounts[0].health == "ready")
        #expect(accounts[0].snapshot?.fiveHour.percent == 4)
        #expect(accounts[0].snapshot?.weekly.percent == 82)
        #expect(accounts[0].snapshot?.fiveHour.resetsAt == Date(timeIntervalSince1970: 1793048400))
        #expect(!accounts[1].isActive)
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

    @Test func rejectsOutputWithoutFiles() {
        #expect(throws: ClaudexError.self) { try parse("{}") }
    }

    @Test func parsesProbedUsage() throws {
        let snapshot = try CLIProxy.parseUsage(Data("""
        {"five_hour": {"utilization": 10.0, "resets_at": "2026-10-26T21:00:00.055871+00:00"},
         "seven_day": {"utilization": 12.0, "resets_at": "2026-10-31T17:00:00+00:00"},
         "seven_day_opus": null}
        """.utf8))
        #expect(snapshot.fiveHour.percent == 10)
        #expect(snapshot.weekly.percent == 12)
        #expect(snapshot.fiveHour.resetsAt != nil)
        #expect(snapshot.weekly.resetsAt != nil)
    }
}
