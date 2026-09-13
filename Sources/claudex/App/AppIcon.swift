import AppKit
import ClaudexCore

/// The Finder and notification icon, drawn rather than authored.
///
/// A menu bar app's icon is seen in three places — the login-items list, a notification, and
/// Finder — and in all three it needs to say which app posted this, not much more. So it is the
/// menu-bar ring at size, on the panel's own dark surface, with no alias in the middle: the
/// letter identifies an account, and the app icon identifies the app.
///
/// Two rings rather than one, because two windows are what the app tracks: the five-hour
/// session inside, the week around it. The pair reads as a gauge at 512 px and as a thick green
/// arc with a lighter halo at 32 px, which is the size the login-items list uses.
///
/// Rendered by the binary itself so the icon cannot drift from the ring it is modelled on;
/// `make icon` calls it and `iconutil` turns the result into `Claudex.icns`.
enum AppIcon {
    /// macOS draws app icons inside a rounded square that leaves roughly a tenth of the canvas
    /// clear on each side, and matching it is what stops the icon looking oversized beside
    /// system apps.
    private static let inset: CGFloat = 100
    private static let cornerRadius: CGFloat = 185

    /// The one reading the mark carries: a session window most of the way through with the
    /// clock a little behind it, and a quieter week around it. Fixed, because an icon showing
    /// live numbers would be a second, slower menu bar.
    private static let session: Double = 0.68
    private static let elapsed: Double = 0.55
    private static let week: Double = 0.42

    /// The dark appearance's green, fixed. `adaptiveGreen` resolves against whatever appearance
    /// is current when the icon is rendered, and the icon's own surface is dark either way.
    private static let green = NSColor(red: 69 / 255, green: 205 / 255, blue: 114 / 255, alpha: 1)

    static func image(side: CGFloat = 1024) -> NSImage {
        let scale = side / 1024
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let box = NSRect(x: 0, y: 0, width: side, height: side)
                .insetBy(dx: inset * scale, dy: inset * scale)
            drawSurface(box, radius: cornerRadius * scale)

            let center = NSPoint(x: box.midX, y: box.midY)

            // The week: outside, thin, dim. It is context for the session ring, so it has to be
            // legible without being the thing the eye lands on.
            drawRing(
                center: center,
                radius: 350 * scale,
                lineWidth: 26 * scale,
                fraction: week,
                colour: green.withAlphaComponent(0.45),
                trackAlpha: 0.08
            )

            // The session: the mark proper, at the weight the menu bar draws it.
            drawGlow(center: center, radius: 225 * scale, lineWidth: 82 * scale, fraction: session)
            drawRing(
                center: center,
                radius: 225 * scale,
                lineWidth: 82 * scale,
                fraction: session,
                colour: green,
                trackAlpha: 0.14
            )
            drawNotch(center: center, radius: 225 * scale, lineWidth: 82 * scale, scale: scale)
            return true
        }
    }

    static func write(to path: String, side: CGFloat = 1024) throws {
        let image = image(side: side)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else {
            throw ClaudexError.unsupportedAccount("Could not encode the icon as PNG")
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// The popover's surface, opaque: an icon has no vibrancy behind it to tint.
    private static func drawSurface(_ box: NSRect, radius: CGFloat) {
        let shape = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
        let gradient = NSGradient(
            starting: NSColor(red: 0.18, green: 0.175, blue: 0.175, alpha: 1),
            ending: NSColor(red: 0.07, green: 0.069, blue: 0.069, alpha: 1)
        )
        gradient?.draw(in: shape, angle: -90)

        // A hairline where the light would catch the edge. Without it the square reads as a hole
        // on a dark desktop.
        shape.lineWidth = max(1, box.width / 512)
        NSColor.white.withAlphaComponent(0.10).setStroke()
        shape.stroke()
    }

    /// Track plus arc, the same two strokes the menu bar draws, at whatever weight is asked for.
    private static func drawRing(
        center: NSPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        fraction: Double,
        colour: NSColor,
        trackAlpha: CGFloat
    ) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.white.withAlphaComponent(trackAlpha).setStroke()
        track.stroke()

        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - 360 * fraction,
            clockwise: true
        )
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        colour.setStroke()
        arc.stroke()
    }

    /// Bloom under the session arc: the same arc stroked wider and fainter, twice. A shadow
    /// would darken the surface instead, and the surface is already near black — what lifts the
    /// arc off it is light spilling outward, not a drop behind it.
    private static func drawGlow(center: NSPoint, radius: CGFloat, lineWidth: CGFloat, fraction: Double) {
        for (spread, alpha) in [(2.1, 0.07), (1.5, 0.10)] as [(CGFloat, CGFloat)] {
            let bloom = NSBezierPath()
            bloom.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - 360 * fraction,
                clockwise: true
            )
            bloom.lineWidth = lineWidth * spread
            bloom.lineCapStyle = .round
            green.withAlphaComponent(alpha).setStroke()
            bloom.stroke()
        }
    }

    /// Same notch as the menu bar: across the stroke, proud either side, so the two marks read
    /// as the same idea at two sizes.
    private static func drawNotch(center: NSPoint, radius: CGFloat, lineWidth: CGFloat, scale: CGFloat) {
        let angle = (90 - 360 * elapsed) * .pi / 180
        let reach = lineWidth / 2 + 30 * scale
        let notch = NSBezierPath()
        notch.move(to: NSPoint(
            x: center.x + cos(angle) * (radius - reach),
            y: center.y + sin(angle) * (radius - reach)
        ))
        notch.line(to: NSPoint(
            x: center.x + cos(angle) * (radius + reach),
            y: center.y + sin(angle) * (radius + reach)
        ))
        notch.lineWidth = 30 * scale
        notch.lineCapStyle = .butt
        NSColor.white.setStroke()
        notch.stroke()
    }
}
