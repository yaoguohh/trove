// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClipDeck",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ClipDeck", targets: ["ClipDeck"])
    ],
    dependencies: [
        // Sparkle: in-app auto-updates. Works on the free (ad-hoc, un-notarized) path via its own
        // EdDSA update signatures — independent of Apple notarization. See memory:
        // distribution-and-update-strategy.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "ClipDeck",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/ClipDeck",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(
            name: "ClipDeckTests",
            dependencies: ["ClipDeck"],
            path: "Tests/ClipDeckTests"
        )
    ]
)
