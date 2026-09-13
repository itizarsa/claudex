import Foundation
import Testing
@testable import ClaudexCore

/// A missing percentage is unknown, never zero. Every assertion here exists because the two
/// look identical in a bar and mean opposite things: one is headroom, the other is no data.
@Suite struct UsageWindowTests {
    @Test func unknownIsNotEmpty() {
        #expect(UsageWindow.unknown.percentText == "-")
        #expect(UsageWindow.unknown.severity == .unknown)
        #expect(UsageWindow.unknown.elapsed == nil)
        #expect(UsageWindow.unknown.pace == nil)
    }

    /// The bar still has to draw something for an unknown window; it draws empty, and the
    /// caller tints it with the unknown colour so it cannot be read as headroom.
    @Test func unknownDrawsEmpty() {
        #expect(UsageWindow.unknown.fraction == 0)
    }

    @Test(arguments: [(-5.0, 0.0), (0.0, 0.0), (42.0, 0.42), (100.0, 1.0), (140.0, 1.0)])
    func fractionIsClamped(percent: Double, expected: Double) {
        let window = UsageWindow(percent: percent, resetsAt: nil, windowSeconds: nil)
        #expect(window.fraction == expected)
    }

    @Test func percentRounds() {
        #expect(UsageWindow(percent: 42.4, resetsAt: nil, windowSeconds: nil).percentText == "42%")
        #expect(UsageWindow(percent: 42.6, resetsAt: nil, windowSeconds: nil).percentText == "43%")
    }

    /// Elapsed is derived from the reset time and the window length, so a quarter of the way
    /// in means three quarters of the window still to run.
    @Test func elapsedReadsTheClockBackwards() {
        let window = UsageWindow(
            percent: nil,
            resetsAt: Date().addingTimeInterval(3 * 3600),
            windowSeconds: 4 * 3600
        )
        let elapsed = try! #require(window.elapsed)
        #expect(abs(elapsed - 0.25) < 0.01)
    }

    /// A reset time in the past is a window that has run out, not one that ran backwards.
    @Test func pastResetIsFullyElapsed() {
        let window = UsageWindow(
            percent: nil,
            resetsAt: Date().addingTimeInterval(-60),
            windowSeconds: 5 * 3600
        )
        #expect(window.elapsed == 1)
    }

    /// One reported window is enough to act on. A snapshot with neither is the shape the
    /// providers reject, because rotating on it would be rotating on nothing.
    @Test func usableNeedsOneWindow() {
        let some = UsageWindow(percent: 10, resetsAt: nil, windowSeconds: nil)
        #expect(UsageSnapshot(fiveHour: some, weekly: .unknown, fetchedAt: Date()).isUsable)
        #expect(UsageSnapshot(fiveHour: .unknown, weekly: some, fetchedAt: Date()).isUsable)
        #expect(!UsageSnapshot(fiveHour: .unknown, weekly: .unknown, fetchedAt: Date()).isUsable)
    }
}
