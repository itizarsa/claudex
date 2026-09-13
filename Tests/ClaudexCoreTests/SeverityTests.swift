import Foundation
import Testing
@testable import ClaudexCore

/// The two readings the whole UI is built on. Both are pure functions of a percentage, so the
/// boundaries are the entire behaviour — and a boundary that slips by one step changes what
/// colour the menu bar shows at 90%.
@Suite struct SeverityTests {
    @Test(arguments: [
        (nil as Double?, Severity.unknown),
        (0, .calm),
        (69.9, .calm),
        (70, .warm),
        (89.9, .warm),
        (90, .hot),
        (100, .hot),
        (140, .hot),
    ])
    func stepsAtSeventyAndNinety(percent: Double?, expected: Severity) {
        #expect(Severity(percent: percent) == expected)
    }
}

@Suite struct PaceTests {
    /// Pace projects spend to the end of the window: 20% burned in 10% of the window projects
    /// to 200%. Each case is (percent, elapsed, projection) with the projection named in the
    /// expectation rather than the numbers, because that is the reading being asserted.
    @Test(arguments: [
        (10.0, 0.5, Pace.comfortable),   // projects to 20%
        (30.0, 0.5, .onTrack),           // 60%
        (40.0, 0.5, .warming),           // 80%
        (47.0, 0.5, .pressing),          // 94%
        (55.0, 0.5, .critical),          // 110%
        (70.0, 0.5, .runaway),           // 140%
    ])
    func sixStepsByProjection(percent: Double, elapsed: Double, expected: Pace) {
        #expect(Pace(percent: percent, elapsed: elapsed) == expected)
    }

    /// Below 3% elapsed the projection divides by a number too small to mean anything, and a
    /// finished window has nothing left to project into.
    @Test(arguments: [nil, 0.0, 0.029, 1.0, 1.5] as [Double?])
    func noReadingOutsideTheUsableSpan(elapsed: Double?) {
        #expect(Pace(percent: 50, elapsed: elapsed) == nil)
    }

    /// Nothing spent is comfortable whatever the clock says — the division would otherwise
    /// report 0% projected as a genuine reading, which it is, but only by accident.
    @Test func nothingSpentIsComfortable() {
        #expect(Pace(percent: 0, elapsed: 0.9) == .comfortable)
        #expect(Pace(percent: nil, elapsed: 0.9) == .comfortable)
    }
}
