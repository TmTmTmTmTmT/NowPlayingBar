// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NowPlayingBar",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        // Floating lyrics / playlist add-on. Knows nothing about the app target.
        .target(
            name: "FloatingLyric",
            path: "Sources/FloatingLyric"
        ),
        .executableTarget(
            name: "NowPlayingBar",
            dependencies: ["FloatingLyric"],
            path: "Sources/NowPlayingBar"
        ),
        .testTarget(
            name: "FloatingLyricTests",
            dependencies: ["FloatingLyric"],
            path: "Tests/FloatingLyricTests"
        ),
    ]
)
