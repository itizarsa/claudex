// swift-tools-version: 6.0
import PackageDescription

// Three targets so the domain can be tested. An executable target cannot be imported, so
// everything worth a test — accounts, the vault, the providers, the rotation rule — lives in
// `ClaudexCore`; the executable keeps the views, the menu bar item and the argument parsing.
let package = Package(
    name: "claudex",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The proxy needs an HTTP server whose request and response bodies are async
        // sequences of buffers, so a model response is forwarded rather than collected.
        // Hummingbird is the smallest such server; URLSession stays the upstream client.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "ClaudexCore",
            dependencies: [.product(name: "Hummingbird", package: "hummingbird")],
            path: "Sources/ClaudexCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "claudex",
            dependencies: ["ClaudexCore"],
            path: "Sources/claudex",
            exclude: [
                "App/AccountBrowser.prototype.html",
                "App/AccountRow.prototype.html",
                "App/UsagePopover.prototype.html",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClaudexCoreTests",
            dependencies: ["ClaudexCore"],
            path: "Tests/ClaudexCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
