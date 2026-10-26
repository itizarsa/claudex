import ClaudexCore
import SwiftUI

/// Claude's own mark, drawn from its published logo path rather than shipped as an asset:
/// the panel needs one glyph at one size, and a vector stays crisp on both scales without a
/// catalogue to maintain. The path is the official mark, normalised to absolute
/// move/line/curve commands in a 24x24 box.
struct ClaudeMark: View {
    var size: CGFloat = 13

    var body: some View {
        LogoShape(commands: claudeMarkPath)
            .fill(Theme.claudeMark)
            .frame(width: size, height: size)
    }
}

/// A reader for the one path dialect the mark is stored in: absolute `M`, `L`, `C`
/// and `Z` over a 24x24 box, scaled to the frame. Arcs and relative commands were flattened
/// out when the paths were imported, which keeps this to a dozen lines rather than a full
/// SVG parser.
private struct LogoShape: Shape {
    let commands: String

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        var path = Path()
        var numbers: [Double] = []
        var command: Character = "M"
        func flush() {
            switch command {
            case "M" where numbers.count == 2:
                path.move(to: point(numbers[0], numbers[1]))
            case "L" where numbers.count == 2:
                path.addLine(to: point(numbers[0], numbers[1]))
            case "C" where numbers.count == 6:
                path.addCurve(
                    to: point(numbers[4], numbers[5]),
                    control1: point(numbers[0], numbers[1]),
                    control2: point(numbers[2], numbers[3])
                )
            case "Z":
                path.closeSubpath()
            default:
                break
            }
            numbers.removeAll(keepingCapacity: true)
        }
        for token in commands.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            if let first = token.first, first.isLetter {
                flush()
                command = first
                if command == "Z" { flush() }
            } else if let value = Double(token) {
                numbers.append(value)
            }
        }
        flush()
        return path
    }
}

// The marks themselves, at the bottom because they are data rather than design.
private let claudeMarkPath =
    """
    M 4.714 15.956 L 9.432 13.308 L 9.511 13.078 L 9.432 12.95 L 9.201 12.95 L 8.412
    12.902 L 5.716 12.829 L 3.379 12.732 L 1.114 12.61 L 0.543 12.489 L 0.009 11.785 L
    0.064 11.432 L 0.543 11.111 L 1.229 11.171 L 2.747 11.275 L 5.024 11.432 L 6.675 11.53
    L 9.122 11.785 L 9.511 11.785 L 9.565 11.627 L 9.432 11.53 L 9.329 11.432 L 6.973
    9.836 L 4.423 8.148 L 3.087 7.176 L 2.365 6.684 L 2.001 6.223 L 1.843 5.215 L 2.498
    4.493 L 3.379 4.553 L 3.603 4.614 L 4.496 5.3 L 6.402 6.776 L 8.892 8.609 L 9.256
    8.913 L 9.402 8.809 L 9.42 8.737 L 9.256 8.463 L 7.902 6.017 L 6.457 3.527 L 5.813
    2.495 L 5.643 1.876 C 5.583 1.621 5.54 1.409 5.54 1.147 L 6.287 0.134 L 6.7 0 L 7.695
    0.134 L 8.114 0.498 L 8.734 1.913 L 9.735 4.141 L 11.29 7.17 L 11.745 8.069 L 11.988
    8.901 L 12.079 9.156 L 12.237 9.156 L 12.237 9.01 L 12.364 7.304 L 12.601 5.209 L
    12.832 2.514 L 12.911 1.755 L 13.287 0.844 L 14.034 0.352 L 14.617 0.631 L 15.096
    1.317 L 15.03 1.761 L 14.744 3.612 L 14.186 6.515 L 13.821 8.457 L 14.034 8.457 L
    14.277 8.215 L 15.26 6.909 L 16.912 4.845 L 17.64 4.025 L 18.49 3.121 L 19.037 2.69 L
    20.069 2.69 L 20.828 3.819 L 20.488 4.985 L 19.425 6.332 L 18.545 7.474 L 17.282 9.174
    L 16.493 10.534 L 16.566 10.643 L 16.754 10.625 L 19.607 10.018 L 21.149 9.738 L
    22.989 9.423 L 23.821 9.811 L 23.912 10.206 L 23.584 11.013 L 21.617 11.499 L 19.31
    11.961 L 15.874 12.774 L 15.831 12.805 L 15.88 12.865 L 17.428 13.011 L 18.09 13.047 L
    19.711 13.047 L 22.728 13.272 L 23.517 13.794 L 23.991 14.432 L 23.912 14.917 L 22.698
    15.537 L 21.058 15.148 L 17.233 14.237 L 15.922 13.909 L 15.74 13.909 L 15.74 14.019 L
    16.833 15.087 L 18.836 16.897 L 21.344 19.228 L 21.471 19.805 L 21.15 20.26 L 20.81
    20.212 L 18.606 18.554 L 17.756 17.807 L 15.831 16.186 L 15.704 16.186 L 15.704 16.356
    L 16.147 17.006 L 18.49 20.527 L 18.612 21.608 L 18.442 21.96 L 17.835 22.173 L 17.167
    22.051 L 15.795 20.127 L 14.38 17.959 L 13.239 16.016 L 13.099 16.095 L 12.425 23.35 L
    12.109 23.721 L 11.381 24 L 10.774 23.539 L 10.452 22.792 L 10.774 21.316 L 11.162
    19.392 L 11.478 17.862 L 11.763 15.961 L 11.933 15.33 L 11.921 15.288 L 11.781 15.306
    L 10.349 17.273 L 8.169 20.218 L 6.445 22.063 L 6.032 22.227 L 5.316 21.857 L 5.382
    21.195 L 5.783 20.606 L 8.169 17.57 L 9.608 15.688 L 10.537 14.602 L 10.531 14.444 L
    10.476 14.444 L 4.138 18.56 L 3.008 18.706 L 2.523 18.25 L 2.583 17.504 L 2.814 17.261
    L 4.721 15.949 Z
    """

