// swift-tools-version: 6.2
// Steam Play for macOS: a SwiftUI front end for scripts/install.sh (GUI interface schema 1).
// No package dependencies: building it downloads nothing.
import PackageDescription

let package = Package(
    name: "SteamPlayApp",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "SteamPlayCore",
            path: "Sources/SteamPlayCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "SteamPlay",
            dependencies: ["SteamPlayCore"],
            path: "Sources/SteamPlay",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SteamPlayCoreTests",
            dependencies: ["SteamPlayCore"],
            path: "Tests/SteamPlayCoreTests"
        ),
    ]
)
