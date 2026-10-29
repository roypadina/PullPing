// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PullPing",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PullPingCore",
            targets: ["PullPingCore"]
        ),
        .executable(
            name: "PullPing",
            targets: ["PullPing"]
        )
    ],
    targets: [
        .target(
            name: "PullPingCore"
        ),
        .executableTarget(
            name: "PullPing",
            dependencies: ["PullPingCore"]
        ),
        .testTarget(
            name: "PullPingCoreTests",
            dependencies: ["PullPingCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
