// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Hourglass",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Hourglass", targets: ["Hourglass"]),
        .executable(name: "hourglass-bridge", targets: ["hourglass-bridge"])
    ],
    targets: [
        // Pure model and logic shared by the app and the bridge. Foundation only.
        .target(
            name: "UsageCore",
            path: "Sources/UsageCore"
        ),
        // The tiny command Claude Code runs as its status line.
        .executableTarget(
            name: "hourglass-bridge",
            dependencies: ["UsageCore"],
            path: "Sources/Bridge"
        ),
        // The notch app itself.
        .executableTarget(
            name: "Hourglass",
            dependencies: ["UsageCore"],
            path: "Sources/Hourglass"
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            path: "Tests/UsageCoreTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
