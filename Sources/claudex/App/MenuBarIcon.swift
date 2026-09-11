import AppKit

/// The menu bar label is drawn into an NSImage rather than composed from SwiftUI shapes,
/// because MenuBarExtra renders its label through the status item and does not lay out
/// arbitrary vector views reliably.
///
/// Three things are encoded, and no more: which account is live (the alias), how much of the
/// five-hour window is spent (the arc), and how far the clock has travelled through it (the
/// notch). Weekly usage tints the unspent track rather than claiming its own row, because the
/// status bar gives us 22 pt of height and nothing else, and a separate rule spent 3 of them.
enum MenuBarIcon {
    static func ring(alias: String, fiveHour: UsageWindow, weekly: UsageWindow) -> NSImage {
        // The status bar will not scale a fitting image, so drawing to its exact thickness is
        // the only way to get every available pixel. Clamped in case the value ever moves.
        let height = min(22, max(18, NSStatusBar.system.thickness))
        // Flush to the canvas: the status bar will scale a taller image back down, so 22 pt is
        // the hard ceiling on diameter and the only way to read larger is to fill all of it.
        let side = height - 0.5
        // Square, because the click highlight fills the status item: any spare width turns the
        // highlight into a pill around a round ring. `AppDelegate` pins the item to match.
        let size = NSSize(width: height, height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            // Thin enough that the ring reads as a rule around the alias rather than a donut:
            // every point of stroke is a point the glyph cannot use.
            let lineWidth: CGFloat = 2
            let ringBox = NSRect(
                x: (size.width - side) / 2,
                y: (height - side) / 2,
                width: side,
                height: side
            )
            let center = NSPoint(x: ringBox.midX, y: ringBox.midY)
            let radius = ringBox.width / 2 - lineWidth / 2

            drawTrack(weekly, center: center, radius: radius, lineWidth: lineWidth)
            drawUsageArc(fiveHour, center: center, radius: radius, lineWidth: lineWidth)
            drawTimeNotch(fiveHour, center: center, radius: radius, lineWidth: lineWidth)
            drawAlias(alias, in: ringBox, lineWidth: lineWidth)

            return true
        }
        image.isTemplate = false
        return image
    }

    /// The track is the unspent part of the session window, tinted by weekly severity. Weekly
    /// only ever needs to answer "is the week also running out", and a hue answers that without
    /// taking space from the arc.
    private static func drawTrack(_ weekly: UsageWindow, center: NSPoint, radius: CGFloat, lineWidth: CGFloat) {
        let tint: NSColor = weekly.percent == nil
            ? NSColor.white.withAlphaComponent(0.16)
            : Severity(percent: weekly.percent).toneNS.withAlphaComponent(0.3)

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        tint.setStroke()
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
        // Fixed length rather than derived from the stroke, so a thin ring does not shrink the
        // notch to a dot. It can only grow inward: the ring is already flush to the canvas, so
        // anything past its outer edge is clipped away. `drawAlias` keeps the glyph clear of it.
        let inner = radius - lineWidth / 2 - 1.75
        let outer = radius + lineWidth / 2

        let notch = NSBezierPath()
        notch.move(to: NSPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
        notch.line(to: NSPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        notch.lineWidth = 1.5
        notch.lineCapStyle = .butt
        NSColor.white.withAlphaComponent(0.92).setStroke()
        notch.stroke()
    }

    /// Sized to the ring's clear interior rather than to a fixed point size, because glyph width
    /// varies more than character count suggests: "W" and "CX" overrun at the size that suits
    /// "C". Shrink-to-fit keeps every alias as large as its own shape allows.
    private static func drawAlias(_ alias: String, in box: NSRect, lineWidth: CGFloat) {
        let text = alias.isEmpty ? "?" : alias
        let available = box.width - 2 * lineWidth - 5
        var size: CGFloat = 14
        var attributes: [NSAttributedString.Key: Any] = [:]
        var measured = NSSize.zero
        while true {
            attributes = [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            ]
            measured = (text as NSString).size(withAttributes: attributes)
            if measured.width <= available || size <= 7 { break }
            size -= 0.5
        }
        // Optical centring: glyphs sit slightly high inside their line box, so nudge down.
        let origin = NSPoint(
            x: box.midX - measured.width / 2,
            y: box.midY - measured.height / 2 + 0.5
        )
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}
