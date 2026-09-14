// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotchNest",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Over-the-air updates from GitHub releases.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "NotchNest",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/NotchNest",
            // Sparkle.framework ships inside the app bundle, in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
