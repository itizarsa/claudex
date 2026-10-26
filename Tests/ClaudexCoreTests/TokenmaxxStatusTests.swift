import Foundation
import Testing
@testable import ClaudexCore

@Suite struct TokenmaxxStatusTests {
    private func parse(_ json: String) throws -> [UsageAccount] {
        try Tokenmaxx.parse(Data(json.utf8))
    }

    @Test func mapsAccountsWindowsAndActive() throws {
        let accounts = try parse("""
        {
          "accounts": [
            {"id": "a", "provider": "anthropic", "identity": "ann@example.com", "plan": "team", "health": "ready", "enabled": true},
            {"id": "b", "provider": "anthropic", "identity": "bob@example.com", "plan": "max", "health": "ready", "enabled": true}
          ],
          "providers": [{"provider": "anthropic", "activeAccountId": "a"}],
          "usage": [
            {"accountId": "a", "observedAt": "2026-10-04T10:06:21.564Z", "windows": [
              {"id": "session", "usedPercent": 4, "resetAt": "2026-10-04T13:20:00.000Z"},
              {"id": "weekly_all", "usedPercent": 82, "resetAt": "2026-10-10T17:00:00Z"},
              {"id": "weekly_scoped:opus", "usedPercent": 99}
            ]},
            {"accountId": "b", "observedAt": "2026-10-04T10:00:00Z", "windows": [
              {"id": "session", "usedPercent": 12},
              {"id": "weekly_all", "usedPercent": 30}
            ]}
          ]
        }
        """)

        #expect(accounts.map(\.id) == ["a", "b"])
        #expect(accounts[0].isActive)
        #expect(accounts[0].plan == "Team")
        #expect(accounts[0].snapshot?.fiveHour.percent == 4)
        #expect(accounts[0].snapshot?.weekly.percent == 82)
        #expect(accounts[0].snapshot?.fiveHour.resetsAt != nil)
        #expect(!accounts[1].isActive)
        #expect(accounts[1].snapshot?.fiveHour.percent == 12)
        #expect(accounts[1].snapshot?.weekly.percent == 30)
    }

    /// Readings for removed accounts are dropped, and an older reading never replaces a newer.
    @Test func keepsNewestReadingForListedAccounts() throws {
        let accounts = try parse("""
        {
          "accounts": [{"id": "a", "provider": "anthropic", "identity": "ann@example.com"}],
          "providers": [],
          "usage": [
            {"accountId": "gone", "observedAt": "2026-10-04T11:00:00Z", "windows": [{"id": "session", "usedPercent": 90}]},
            {"accountId": "a", "observedAt": "2026-10-04T11:00:00Z", "windows": [{"id": "session", "usedPercent": 50}]},
            {"accountId": "a", "observedAt": "2026-10-04T10:00:00Z", "windows": [{"id": "session", "usedPercent": 10}]}
          ]
        }
        """)

        #expect(accounts.count == 1)
        #expect(accounts[0].snapshot?.fiveHour.percent == 50)
        #expect(accounts[0].snapshot?.weekly == .unknown)
    }

    @Test func skipsOtherProvidersAndDisabledAccounts() throws {
        let accounts = try parse("""
        {
          "accounts": [
            {"id": "g", "provider": "xai", "identity": "g@example.com"},
            {"id": "o", "provider": "openai", "identity": "o@example.com"},
            {"id": "d", "provider": "anthropic", "identity": "d@example.com", "enabled": false}
          ],
          "providers": [],
          "usage": []
        }
        """)
        #expect(accounts.isEmpty)
    }

    @Test func accountWithoutUsageHasNoSnapshot() throws {
        let accounts = try parse("""
        {"accounts": [{"id": "a", "provider": "anthropic", "identity": "ann@example.com"}], "providers": [], "usage": []}
        """)
        #expect(accounts[0].snapshot == nil)
    }

    @Test func rejectsOutputWithoutAccounts() {
        #expect(throws: ClaudexError.self) { try parse("{}") }
    }
}
