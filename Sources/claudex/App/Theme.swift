import SwiftUI

/// One place for surface, type and spacing decisions so the popover and the ring agree.
///
/// Deliberately no decorative accent colour. The only colours that carry meaning are the
/// three severity steps, and adding a fourth hue for "active" would compete with them. Active
/// state is shown through weight and fill instead.
enum Theme {
    // Surfaces. The panel is a dark tint over the popover's material rather than an opaque
    // fill, so it reads as system chrome instead of a window pasted onto the menu bar.
    // Everything above it is a white overlay, which keeps one grey family by construction.
    static let popoverTint = Color(nsColor: NSColor(calibratedRed: 0.055, green: 0.055, blue: 0.063, alpha: 1))
        .opacity(0.76)
    static let card = Color.white.opacity(0.045)
    static let cardHover = Color.white.opacity(0.08)
    static let cardStroke = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.08)
    static let track = Color.white.opacity(0.1)

    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.58)
    static let tertiaryText = Color.white.opacity(0.38)

    // One radius scale, three steps by depth: container, control, bar.
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 7
    static let barRadius: CGFloat = 2

    static let cardPadding: CGFloat = 11
    // The bar is a reading aid under the percentage, not the headline. Thin keeps it that way.
    static let barHeight: CGFloat = 4
    static let popoverWidth: CGFloat = 280

    static let transition: Animation = .easeOut(duration: 0.18)

    // Type. Numbers are tabular everywhere so percentages stop jittering between polls.
    static func percent(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }
    static let accountName = Font.system(size: 13, weight: .semibold)
    static let plan = Font.system(size: 11, weight: .medium)
    static let windowLabel = Font.system(size: 11, weight: .medium)
    static let caption = Font.system(size: 10, weight: .regular)
    static let sectionHeader = Font.system(size: 11, weight: .semibold)
    static let pill = Font.system(size: 9.5, weight: .semibold)
}

/// Severity colours, desaturated so they read as data rather than as alarms.
extension Severity {
    var tone: Color {
        switch self {
        case .unknown: return Theme.tertiaryText
        case .calm: return Color(nsColor: NSColor(calibratedRed: 0.353, green: 0.769, blue: 0.463, alpha: 1))
        case .warm: return Color(nsColor: NSColor(calibratedRed: 0.898, green: 0.635, blue: 0.278, alpha: 1))
        case .hot: return Color(nsColor: NSColor(calibratedRed: 0.878, green: 0.400, blue: 0.365, alpha: 1))
        }
    }

    var toneNS: NSColor {
        switch self {
        case .unknown: return NSColor.white.withAlphaComponent(0.36)
        case .calm: return NSColor(calibratedRed: 0.353, green: 0.769, blue: 0.463, alpha: 1)
        case .warm: return NSColor(calibratedRed: 0.898, green: 0.635, blue: 0.278, alpha: 1)
        case .hot: return NSColor(calibratedRed: 0.878, green: 0.400, blue: 0.365, alpha: 1)
        }
    }
}
