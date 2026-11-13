// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Trove",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Trove", targets: ["Trove"])
    ],
    dependencies: [
        // Sparkle: in-app auto-updates. Works on the free (ad-hoc, un-notarized) path via its own
        // EdDSA update signatures — independent of Apple notarization. See RELEASE.md.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Trove",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .testTarget(
            name: "TroveTests",
            dependencies: ["Trove"]
        )
    ]
)
