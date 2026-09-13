import Foundation
import Testing
@testable import ClaudexCore

@Suite struct RotationTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let thresholds = ProviderThresholds(fiveHour: 85, weekly: 90)

    private func account(_ label: String, order: Int) -> Account {
        Account(
            provider: .claude,
            label: label,
            identity: Identity(
                email: "\(label)@example.com",
                displayName: label,
                plan: "Max",
                organization: nil,
                organizationID: nil,
                remoteID: label
            ),
            order: order
        )
    }

    private func snapshot(
        fiveHour: Double?,
        weekly: Double?,
        age: TimeInterval = 0
    ) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageWindow(percent: fiveHour, resetsAt: nil, windowSeconds: 18_000),
            weekly: UsageWindow(percent: weekly, resetsAt: nil, windowSeconds: 604_800),
            fetchedAt: now.addingTimeInterval(-age)
        )
    }

    @Test func choosesLowestSessionThenWeeklyThenOrder() {
        let active = account("Active", order: 0)
        let first = account("First", order: 1)
        let best = account("Best", order: 2)
        let fleet = Fleet(
            active: RotationCandidate(account: active, snapshot: snapshot(fiveHour: 90, weekly: 20)),
            candidates: [
                RotationCandidate(account: first, snapshot: snapshot(fiveHour: 30, weekly: 10)),
                RotationCandidate(account: best, snapshot: snapshot(fiveHour: 20, weekly: 80)),
            ]
        )

        #expect(Rotation.decide(fleet: fleet, thresholds: thresholds, lastSwitch: nil, now: now) == .switchTo(best.id))
    }

    @Test func staleAndUnknownCandidatesBlockRotation() {
        let active = account("Active", order: 0)
        let fleet = Fleet(
            active: RotationCandidate(account: active, snapshot: snapshot(fiveHour: 90, weekly: 20)),
            candidates: [
                RotationCandidate(account: account("Stale", order: 1), snapshot: snapshot(fiveHour: 10, weekly: 10, age: 601)),
                RotationCandidate(account: account("Unknown", order: 2), snapshot: snapshot(fiveHour: nil, weekly: 10)),
            ]
        )

        #expect(Rotation.decide(fleet: fleet, thresholds: thresholds, lastSwitch: nil, now: now) == .blocked(.fiveHour))
    }

    @Test func cooldownSuppressesOtherwiseValidSwitch() {
        let active = account("Active", order: 0)
        let candidate = account("Candidate", order: 1)
        let fleet = Fleet(
            active: RotationCandidate(account: active, snapshot: snapshot(fiveHour: 90, weekly: 20)),
            candidates: [RotationCandidate(account: candidate, snapshot: snapshot(fiveHour: 10, weekly: 10))]
        )

        #expect(Rotation.decide(
            fleet: fleet,
            thresholds: thresholds,
            lastSwitch: now.addingTimeInterval(-30),
            now: now
        ) == .stay)
    }

    @Test func weeklyExhaustionNamesWeeklyWindow() {
        let active = account("Active", order: 0)
        let fleet = Fleet(
            active: RotationCandidate(account: active, snapshot: snapshot(fiveHour: 20, weekly: 95)),
            candidates: []
        )

        #expect(Rotation.decide(fleet: fleet, thresholds: thresholds, lastSwitch: nil, now: now) == .blocked(.weekly))
    }
}
