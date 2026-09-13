import ClaudexCore
import SwiftUI

/// One place for surface, type and spacing decisions so the popover and the ring agree.
///
/// The values match Claude Usage Tracker's popover, which is the look this app is aiming at:
/// a `.hudWindow` vibrancy layer under a flat tint, outlined cards with no fill, and one
/// accent hue for identity that stays clear of the three severity steps carrying usage.
enum Theme {
    // Surfaces. The tint sits on top of the material rather than replacing it, so the panel
    // reads as system chrome. `VisualEffectBackground` supplies the material underneath.
    static let popoverTint = Color.black.opacity(0.25)
    /// Cards are outlined, not filled. The fill appears only under the pointer, which is the
    /// one moment a card needs to separate itself from its neighbours.
    static let card = Color.clear
    static let cardHover = Color.primary.opacity(0.05)
    static let cardStroke = Color.primary.opacity(0.1)
    static let hairline = Color.primary.opacity(0.1)
    /// Sampled from the reference: its unfilled track is #383636 against a #212020 card. Ours
    /// sits on vibrancy rather than a flat fill, so the value is expressed as a white overlay
    /// that lands on the same grey over that background.
    static let track = Color.white.opacity(0.13)
    /// The identity hue: alias badge and the active tag, both at low opacity. Kept distinct
    /// from severity so "which account" and "how full" never compete.
    static let accent = Color.accentColor
    /// Each provider's own hue, used only by its mark so a section is identifiable before
    /// the header is read.
    static let claudeMark = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codexMark = Color(white: 0.88)

    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color.secondary.opacity(0.75)

    // One radius scale, three steps by depth: container, control, bar.
    static let cardRadius: CGFloat = 8
    static let controlRadius: CGFloat = 6
    static let barRadius: CGFloat = 1.5

    // A hairline at 0.5 rather than 1: the border defines the card's edge without becoming a
    // line the eye has to read past on every row.
    static let cardStrokeWidth: CGFloat = 0.5
    static let cardPaddingH: CGFloat = 10
    /// The rail marking the live account. Two points: enough to read as a marked edge from
    /// across the desktop, thin enough not to become a fourth colour in the card.
    static let activeRailWidth: CGFloat = 2
    static let cardPaddingV: CGFloat = 8
    // The bar is a reading aid under the percentage, not the headline. Thin keeps it that way:
    // the reference's 8 px at 2x competed with the number above it, so the bar is drawn at
    // half that — a rule carrying a colour rather than a block of one. The elapsed marker
    // keeps its proportion and stands 2 pt proud of the bar at each end.
    static let barHeight: CGFloat = 3
    static let barMarkerWidth: CGFloat = 2
    static let popoverWidth: CGFloat = 280

    static let transition: Animation = .easeOut(duration: 0.18)
    /// Long enough to read as a level changing rather than a value being replaced.
    static let barFill: Animation = .easeInOut(duration: 0.6)

    // Type. Numbers are tabular everywhere so percentages stop jittering between polls.
    static func percent(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }
    static let percentSize: CGFloat = 13
    static let accountName = Font.system(size: 11, weight: .semibold)
    static let alias = Font.system(size: 12, weight: .bold, design: .rounded)
    static let aliasBadgeSize: CGFloat = 24
    static let plan = Font.system(size: 9, weight: .medium)
    static let windowLabel = Font.system(size: 13, weight: .medium)
    static let subtitle = Font.system(size: 10, weight: .regular)
    static let caption = Font.system(size: 9, weight: .regular)
    static let sectionHeader = Font.system(size: 11, weight: .semibold)
    static let pill = Font.system(size: 9, weight: .medium)
    /// The organisation beside an account's name. A step under the name it qualifies.
    static let chip = Font.system(size: 8, weight: .semibold)
    static let activeTag = Font.system(size: 8, weight: .semibold)
}

/// The popover's backdrop: a HUD vibrancy layer with a flat tint over it. The tint is what
/// gives the panel density; the material alone reads too thin against a bright desktop.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Severity colours. Thresholds and hues both follow Claude Usage Tracker: safe under 70,
/// moderate to 90, critical above.
extension Severity {
    var tone: Color {
        switch self {
        case .unknown: return Theme.tertiaryText
        case .calm: return .adaptiveGreen
        case .warm: return .orange
        case .hot: return Color(nsColor: .usageRed)
        }
    }

    var toneNS: NSColor {
        switch self {
        case .unknown: return NSColor.secondaryLabelColor
        case .calm: return .adaptiveGreen
        case .warm: return .systemOrange
        case .hot: return .usageRed
        }
    }
}

/// Pace colours. Six steps against severity's three, because pace is the reading that changes
/// behaviour; the extra resolution is the point.
extension Pace {
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

extension Color {
    /// System green is too dark to read on a light translucent surface and slightly dull on a
    /// dark one, so each appearance gets its own value.
    static let adaptiveGreen = Color(nsColor: .adaptiveGreen)
}

extension NSColor {
    /// Both sampled from the reference's own pixels: #45CD72 and #FF6058. System red and green
    /// are darker and more saturated, which is what made the same layout read as harsher here.
    static let adaptiveGreen = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 69 / 255, green: 205 / 255, blue: 114 / 255, alpha: 1)
            : NSColor(red: 27 / 255, green: 107 / 255, blue: 52 / 255, alpha: 1)
    }

    static let usageRed = NSColor(red: 255 / 255, green: 96 / 255, blue: 88 / 255, alpha: 1)
}
