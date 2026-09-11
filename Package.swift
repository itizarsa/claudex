// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "claudex",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "claudex",
            path: "Sources/claudex",
            exclude: ["App/UsagePopover.prototype.html"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
