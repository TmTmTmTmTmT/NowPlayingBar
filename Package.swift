// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NowPlayingBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "NowPlayingBar",
            path: "Sources/NowPlayingBar"
        )
    ]
)
