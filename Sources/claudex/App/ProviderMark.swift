import ClaudexCore
import SwiftUI

/// The provider's own mark, drawn from its published logo path rather than shipped as an
/// asset: the panel needs one glyph at one size, and a vector stays crisp on both scales
/// without a catalogue to maintain. Both paths are the official marks, normalised to
/// absolute move/line/curve commands in a 24x24 box.
struct ProviderMark: View {
    let kind: ProviderKind
    var size: CGFloat = 13

    var body: some View {
        LogoShape(commands: kind.markPath)
            .fill(kind.markColor, style: FillStyle(eoFill: kind == .codex))
            .frame(width: size, height: size)
    }
}

private extension ProviderKind {
    var markColor: Color {
        switch self {
        case .claude: return Theme.claudeMark
        case .codex: return Theme.codexMark
        }
    }

    var markPath: String {
        switch self {
        case .claude: return claudeMarkPath
        case .codex: return openAIMarkPath
        }
    }
}

/// A reader for the one path dialect these two marks are stored in: absolute `M`, `L`, `C`
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

private let openAIMarkPath =
    """
    M 9.205 8.658 L 9.205 6.398 C 9.205 6.208 9.277 6.065 9.443 5.97 L 13.986 3.354 C
    14.605 2.997 15.342 2.831 16.103 2.831 C 18.957 2.831 20.765 5.043 20.765 7.397 C
    20.765 7.564 20.765 7.754 20.741 7.944 L 16.031 5.185 C 15.77 5.019 15.436 5.019
    15.175 5.185 L 9.205 8.658 Z M 19.814 17.458 L 19.814 12.06 C 19.814 11.727 19.671
    11.49 19.385 11.323 L 13.415 7.85 L 15.365 6.732 C 15.509 6.637 15.697 6.637 15.841
    6.732 L 20.384 9.349 C 21.693 10.109 22.573 11.727 22.573 13.297 C 22.573 15.105
    21.503 16.77 19.813 17.46 Z M 7.802 12.703 L 5.852 11.561 C 5.685 11.466 5.613 11.323
    5.613 11.133 L 5.613 5.899 C 5.613 3.354 7.563 1.427 10.204 1.427 C 11.204 1.427
    12.131 1.76 12.916 2.355 L 8.23 5.067 C 7.945 5.233 7.802 5.471 7.802 5.804 L 7.802
    12.702 Z M 12 15.128 L 9.205 13.558 L 9.205 10.228 L 12 8.658 L 14.795 10.228 L 14.795
    13.558 L 12 15.128 Z M 13.796 22.358 C 12.796 22.358 11.869 22.026 11.084 21.431 L
    15.77 18.719 C 16.055 18.553 16.198 18.315 16.198 17.982 L 16.198 11.084 L 18.172
    12.226 C 18.339 12.321 18.41 12.464 18.41 12.654 L 18.41 17.887 C 18.41 20.432 16.436
    22.359 13.796 22.359 Z M 8.159 17.055 L 3.615 14.438 C 2.307 13.677 1.427 12.06 1.427
    10.49 C 1.421 8.665 2.521 7.019 4.21 6.327 L 4.21 11.75 C 4.21 12.083 4.353 12.321
    4.638 12.488 L 10.585 15.937 L 8.635 17.055 C 8.491 17.15 8.303 17.15 8.159 17.055 Z M
    7.897 20.955 C 5.209 20.955 3.235 18.934 3.235 16.436 C 3.235 16.246 3.259 16.056
    3.282 15.866 L 7.968 18.576 C 8.254 18.743 8.539 18.743 8.824 18.576 L 14.794 15.128 L
    14.794 17.388 C 14.794 17.578 14.724 17.721 14.557 17.816 L 10.014 20.432 C 9.395
    20.789 8.658 20.955 7.897 20.955 Z M 13.796 23.785 C 16.622 23.785 19.057 21.797
    19.623 19.029 C 22.287 18.339 24 15.84 24 13.296 C 24 11.631 23.287 10.014 22.002
    8.848 C 22.121 8.348 22.192 7.849 22.192 7.35 C 22.192 3.949 19.433 1.403 16.246 1.403
    C 15.604 1.403 14.986 1.498 14.366 1.713 C 13.256 0.62 11.763 0.006 10.205 0 C 7.379
    -0 4.943 1.988 4.378 4.757 C 1.713 5.447 0 7.945 0 10.49 C 0 12.156 0.713 13.773 1.998
    14.938 C 1.879 15.438 1.808 15.938 1.808 16.437 C 1.808 19.838 4.567 22.383 7.754
    22.383 C 8.396 22.383 9.014 22.288 9.634 22.074 C 10.744 23.167 12.238 23.782 13.796
    23.787 Z
    """
