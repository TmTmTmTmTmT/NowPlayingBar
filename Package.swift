// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NowPlayingBar",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "NowPlayingBar",
            path: "Sources/NowPlayingBar"
        )
    ]
)
