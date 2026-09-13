import AppKit
import ClaudexCore

/// The menu bar label is drawn into an NSImage rather than composed from SwiftUI shapes,
/// because MenuBarExtra renders its label through the status item and does not lay out
/// arbitrary vector views reliably.
///
/// Three things are encoded per ring, and no more: which account is live (the alias), how much
/// of the five-hour window is spent (the arc), and how far the clock has travelled through it
/// (the notch, tinted by pace). Ring geometry follows Claude Usage Tracker — 22 pt canvas,
/// 9.5 pt centreline radius, 3 pt stroke, neutral track under a tinted arc. No weekly bar under
/// the ring; weekly lives in the popover.
///
/// Every provider's ring is drawn into one image rather than one status item each. Separate
/// items look the same but behave as separate controls: two click targets opening the panel,
/// and two things to drag into place. One image keeps the set together.
enum MenuBarIcon {
    struct Entry {
        var alias: String
        var fiveHour: UsageWindow
    }

    /// Points between adjacent rings. The notch already spends the point either side of each
    /// ring, so this is the gap over and above that.
    private static let gap: CGFloat = 4

    static func rings(_ entries: [Entry]) -> NSImage {
        // The status bar will not scale a fitting image, so drawing to its exact thickness is
        // the only way to get every available pixel. Clamped in case the value ever moves.
        let height = min(22, max(18, NSStatusBar.system.thickness))
        // The ring is drawn to the full bar height, as the reference does: measured off a 2x
        // capture, its ring is 44 px across on a 44 px bar, with a 6 px stroke.
        let side = height
        // Each ring gets its diameter plus a point either side, because the notch reaches a
        // quarter point past the outer edge and a tight canvas would clip it flat.
        let slot = side + 2
        let count = max(1, entries.count)
        let size = NSSize(width: slot * CGFloat(count) + gap * CGFloat(count - 1), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            // Heavy enough that the arc reads as a gauge at a glance rather than a hairline,
            // which is the one thing the ring has to do from across a 22 pt strip.
            let lineWidth: CGFloat = 3
            // Centreline radius, so the stroke's outer edge lands on the canvas edge: 9.5 pt on
            // a 22 pt bar, matching the reference's 44 px outer diameter at 2x.
            let radius = side / 2 - lineWidth / 2

            for (index, entry) in entries.enumerated() {
                let ringBox = NSRect(
                    x: (slot + gap) * CGFloat(index) + (slot - side) / 2,
                    y: 0,
                    width: side,
                    height: side
                )
                let center = NSPoint(x: ringBox.midX, y: ringBox.midY)

                drawTrack(center: center, radius: radius, lineWidth: lineWidth)
                drawUsageArc(entry.fiveHour, center: center, radius: radius, lineWidth: lineWidth)
                drawTimeNotch(entry.fiveHour, center: center, radius: radius, lineWidth: lineWidth)
                drawAlias(entry.alias, in: ringBox, radius: radius, lineWidth: lineWidth)
            }

            return true
        }
        image.isTemplate = false
        return image
    }

    /// Width the status item must be pinned to for `count` rings. `variableLength` pads the
    /// button wider than its image and the click highlight fills all of it, so a pill would
    /// otherwise appear around the rings.
    static func width(forRings count: Int) -> CGFloat {
        let side = min(22, max(18, NSStatusBar.system.thickness))
        let slot = side + 2
        return slot * CGFloat(max(1, count)) + gap * CGFloat(max(0, count - 1))
    }

    /// The full circle, always drawn, neutral. It is what makes a 20% arc read as "20% of a
    /// ring" instead of a stray stroke, and it keeps the icon the same shape at every level.
    private static func drawTrack(center: NSPoint, radius: CGFloat, lineWidth: CGFloat) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        track.lineCapStyle = .round
        // Solid enough to read as a track on the menu bar's own translucency. At 0.15 the
        // unfilled part of the ring disappeared and a partial arc looked like a stray stroke;
        // at 0.28 it competed with the arc. The reference could not settle this — every capture
        // of it is at 100%, where no track shows — so this is the one value here not measured.
        NSColor.white.withAlphaComponent(0.2).setStroke()
        track.stroke()
    }

    private static func drawUsageArc(_ window: UsageWindow, center: NSPoint, radius: CGFloat, lineWidth: CGFloat) {
        guard window.percent != nil, window.fraction > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - 360 * window.fraction,
            clockwise: true
        )
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        Severity(percent: window.percent).toneNS.setStroke()
        arc.stroke()
    }

    /// A notch cut across the ring at the point the clock has reached. Usage arc short of the
    /// notch means the window is refilling faster than it is being spent.
    private static func drawTimeNotch(_ window: UsageWindow, center: NSPoint, radius: CGFloat, lineWidth: CGFloat) {
        guard let elapsed = window.elapsed else { return }
        let angle = (90 - 360 * elapsed) * .pi / 180
        // Symmetric about the ring and proud of it on both sides. Crossing the stroke rather
        // than sitting inside it is what lets the notch be read against a full arc. The
        // reference's is 11 px long and 5 px thick at 2x, straddling its stroke; these are the
        // same figures in points.
        let inner = radius - 2.75
        let outer = radius + 2.75

        let notch = NSBezierPath()
        notch.move(to: NSPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
        notch.line(to: NSPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        notch.lineWidth = 2.5
        // Butt, not round: round caps add half the stroke width at each end, which overshot the
        // reference's 11 px tick by three pixels and pushed it into the canvas edge.
        notch.lineCapStyle = .butt
        (Pace(percent: window.percent, elapsed: elapsed)?.toneNS ?? .white).setStroke()
        notch.stroke()
    }

    /// The reference sets a small letter into the ring rather than filling it: 12 px cap height
    /// at 2x inside a 32 px clear interior. Filling the interior instead — which is what an
    /// unbounded fit does — crowds the arc and is the single thing that made our ring read as
    /// heavier than the app it copies.
    ///
    /// So the size is fixed, and the fit loop only takes over for a two-character alias that
    /// would not otherwise clear the ring. The limit is the glyph's diagonal against the inner
    /// clear diameter, because the interior is a circle rather than a box. Measured on cap
    /// height rather than the line box, which is mostly ascender and descender space that no
    /// uppercase alias occupies.
    private static func drawAlias(_ alias: String, in box: NSRect, radius: CGFloat, lineWidth: CGFloat) {
        let text = alias.isEmpty ? "?" : alias
        // The inner clear diameter, less a couple of points of breathing room: a two-character
        // alias measured flush against the stroke technically fits, but reads as jammed into it.
        let clear = 2 * (radius - lineWidth / 2) - 3

        var size: CGFloat = 11
        var font = NSFont.systemFont(ofSize: size, weight: .regular)
        var width: CGFloat = 0
        while true {
            font = NSFont.systemFont(ofSize: size, weight: .regular)
            width = (text as NSString).size(withAttributes: [.font: font]).width
            if hypot(width, font.capHeight) <= clear || size <= 7 { break }
            size -= 0.5
        }

        // Centre the cap band, not the line box: `draw(at:)` places the line box's bottom-left,
        // so back out the descender to put the baseline where cap height straddles the middle.
        let origin = NSPoint(
            x: box.midX - width / 2,
            y: box.midY - font.capHeight / 2 + font.descender
        )
        (text as NSString).draw(at: origin, withAttributes: [
            .font: font,
            .foregroundColor: NSColor.white,
        ])
    }
}
