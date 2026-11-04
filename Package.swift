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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .target(
            name: "PullPingCore"
        ),
        .executableTarget(
            name: "PullPing",
            dependencies: ["PullPingCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is embedded in Contents/Frameworks (Scripts/package_app.sh). dyld resolves
            // @executable_path through the cask's `pullping` symlink, so the CLI finds it too.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "PullPingCoreTests",
            dependencies: ["PullPingCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PullPingScreenshotTests",
            dependencies: ["PullPing", "PullPingCore"]
        )
    ]
)
