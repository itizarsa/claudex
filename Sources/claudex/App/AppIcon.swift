import AppKit
import ClaudexCore

/// The Finder and notification icon, drawn rather than authored.
///
/// A menu bar app's icon is seen in three places — the login-items list, a notification, and
/// Finder — and in all three it needs to say which app posted this, not much more. So it is the
/// menu-bar ring at size, on the panel's own dark surface, with no alias in the middle: the
/// letter identifies an account, and the app icon identifies the app.
///
/// Rendered by the binary itself so the icon cannot drift from the ring it is modelled on;
/// `make icon` calls it and `iconutil` turns the result into `Claudex.icns`.
enum AppIcon {
    /// macOS draws app icons inside a rounded square that leaves roughly a tenth of the canvas
    /// clear on each side, and matching it is what stops the icon looking oversized beside
    /// system apps.
    private static let inset: CGFloat = 100
    private static let cornerRadius: CGFloat = 185

    /// The one reading the mark carries: a window most of the way through, with the clock a
    /// little behind it. Fixed, because an icon showing live numbers would be a second,
    /// slower menu bar.
    private static let usage: Double = 0.68
    private static let elapsed: Double = 0.55

    static func image(side: CGFloat = 1024) -> NSImage {
        let scale = side / 1024
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let box = NSRect(x: 0, y: 0, width: side, height: side)
                .insetBy(dx: inset * scale, dy: inset * scale)
            drawSurface(box, radius: cornerRadius * scale)

            let center = NSPoint(x: box.midX, y: box.midY)
            let lineWidth = 74 * scale
            let radius = 260 * scale
            drawRing(center: center, radius: radius, lineWidth: lineWidth, scale: scale)
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
            starting: NSColor(red: 0.16, green: 0.155, blue: 0.155, alpha: 1),
            ending: NSColor(red: 0.09, green: 0.088, blue: 0.088, alpha: 1)
        )
        gradient?.draw(in: shape, angle: -90)

        // A hairline where the light would catch the edge. Without it the square reads as a hole
        // on a dark desktop.
        shape.lineWidth = max(1, box.width / 512)
        NSColor.white.withAlphaComponent(0.08).setStroke()
        shape.stroke()
    }

    private static func drawRing(center: NSPoint, radius: CGFloat, lineWidth: CGFloat, scale: CGFloat) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.white.withAlphaComponent(0.13).setStroke()
        track.stroke()

        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - 360 * usage,
            clockwise: true
        )
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        NSColor.adaptiveGreen.setStroke()
        arc.stroke()

        // Same notch as the menu bar: across the stroke, proud either side, so the two marks
        // read as the same idea at two sizes.
        let angle = (90 - 360 * elapsed) * .pi / 180
        let reach = lineWidth / 2 + 34 * scale
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
