import SwiftUI

enum Severity {
    case unknown
    case calm      // < 60
    case warm      // 60 ..< 85
    case hot       // >= 85

    init(percent: Double?) {
        guard let percent else { self = .unknown; return }
        switch percent {
        case ..<60: self = .calm
        case ..<85: self = .warm
        default: self = .hot
        }
    }

    /// Colours live in `Theme` as `tone` / `toneNS`.
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

    /// Fraction for bar and ring drawing. Unknown reads as empty, and callers render the
    /// unknown severity colour so it is never mistaken for genuine headroom.
    var fraction: Double { min(1, max(0, (percent ?? 0) / 100)) }
}
