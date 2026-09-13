import SwiftUI

enum Severity {
    case unknown
    case calm      // < 70
    case warm      // 70 ..< 90
    case hot       // >= 90

    init(percent: Double?) {
        guard let percent else { self = .unknown; return }
        switch percent {
        case ..<70: self = .calm
        case ..<90: self = .warm
        default: self = .hot
        }
    }

    /// Colours live in `Theme` as `tone` / `toneNS`.
}

/// How the spend rate compares to the clock, projected to the end of the window. Six steps
/// rather than severity's three, because this is the reading that changes behaviour: a bar at
/// 40% means nothing until you know whether 40% arrived in an hour or in four.
///
/// Only the elapsed-time marker is tinted with it. The bar keeps severity, so "how full" and
/// "how fast" stay separable at a glance.
enum Pace {
    case comfortable   // projected < 50%
    case onTrack       // 50 ..< 75
    case warming       // 75 ..< 90
    case pressing      // 90 ..< 100
    case critical      // 100 ..< 120
    case runaway       // >= 120

    /// Nil below 3% elapsed, where the projection divides by a number too small to mean
    /// anything, and once the window is over.
    init?(percent: Double?, elapsed: Double?) {
        guard let elapsed, elapsed >= 0.03, elapsed < 1 else { return nil }
        guard let percent, percent > 0 else { self = .comfortable; return }
        switch (percent / 100) / elapsed {
        case ..<0.50: self = .comfortable
        case ..<0.75: self = .onTrack
        case ..<0.90: self = .warming
        case ..<1.00: self = .pressing
        case ..<1.20: self = .critical
        default: self = .runaway
        }
    }

    var tone: Color {
        switch self {
        case .comfortable: return .green
        case .onTrack: return .teal
        case .warming: return .yellow
        case .pressing: return .orange
        case .critical: return .red
        case .runaway: return .purple
        }
    }

    var toneNS: NSColor {
        switch self {
        case .comfortable: return .systemGreen
        case .onTrack: return .systemTeal
        case .warming: return .systemYellow
        case .pressing: return .systemOrange
        case .critical: return .systemRed
        case .runaway: return .systemPurple
        }
    }
}

extension UsageWindow {
    var severity: Severity { Severity(percent: percent) }

    var percentText: String {
        guard let percent else { return "-" }
        return "\(Int(percent.rounded()))%"
    }

    /// Absolute reset time reads better than a countdown: "Resets Today 10:00PM" tells you
    /// whether it lands before you stop working, which "resets in 4h 33m" makes you compute.
    var resetText: String { Formatting.resetLine(resetsAt) }

    var pace: Pace? { Pace(percent: percent, elapsed: elapsed) }

    /// Fraction for bar and ring drawing. Unknown reads as empty, and callers render the
    /// unknown severity colour so it is never mistaken for genuine headroom.
    var fraction: Double { min(1, max(0, (percent ?? 0) / 100)) }
}
