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
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // PermissionFlow: opens the right System Settings privacy pane with a floating, draggable
        // app card beside it — the Accessibility guide. Resources ship in its own bundle (see
        // scripts/package-app.sh).
        .package(url: "https://github.com/jaywcjlove/PermissionFlow", from: "2.11.4")
    ],
    targets: [
        .executableTarget(
            name: "Trove",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "PermissionFlow", package: "PermissionFlow")
            ]
        ),
        .testTarget(
            name: "TroveTests",
            dependencies: ["Trove"]
        )
    ]
)
