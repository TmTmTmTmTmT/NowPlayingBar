import XCTest
@testable import FloatingLyric

/// Writes PNGs of `PlaylistView` for eyeballing; does nothing unless `LYRIC_SNAPSHOT_DIR` is set.
@MainActor
final class PlaylistViewSnapshotTests: XCTestCase {
    private func snapshot(count: Int, first: Int = 1, total: Int? = nil, current: Int) -> PlaylistSnapshot {
        let tracks = (0..<count).map {
            PlaylistTrack(index: first + $0, title: "Track \(first + $0)", artist: "Artist \(($0 % 5) + 1)",
                          duration: 150 + Double($0 * 7 % 200))
        }
        return PlaylistSnapshot(name: "Sample Playlist", tracks: tracks, currentIndex: current,
                                totalCount: total ?? count, firstIndex: first)
    }

    private func render(_ result: PlaylistResult, name: String, clear: Bool, dark: Bool, dir: String,
                        loader: Bool = true) throws {
        let view = PlaylistView(frame: NSRect(x: 0, y: 0, width: 340, height: 440))
        view.artworkLoader = loader ? { index, done in
            let size = NSSize(width: 64, height: 64)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor(hue: CGFloat(index % 12) / 12, saturation: 0.5, brightness: 0.8, alpha: 1).setFill()
                rect.fill()
                return true
            }
            done(index % 7 == 0 ? nil : image)
        } : nil
        view.apply(glass: GlassAppearance(isClear: clear, blurHidden: true, blurOpacity: 0.58,
                                          pinnedDark: dark, solidElements: clear))
        let backdrop = NSView(frame: view.frame)
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = (dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.85, alpha: 1)).cgColor
        backdrop.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        backdrop.addSubview(view)
        view.show(result: result)
        if case .snapshot = result { view.updateCurrent(index: 12, isPlaying: true) }
        backdrop.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let file = "\(dir)/\(name)-\(clear ? "clear" : "regular")-\(dark ? "dark" : "light").png"
        try png.write(to: URL(fileURLWithPath: file))
    }

    func testWritePNGs() throws {
        guard let dir = ProcessInfo.processInfo.environment["LYRIC_SNAPSHOT_DIR"] else {
            throw XCTSkip("LYRIC_SNAPSHOT_DIR not set")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cases: [(String, PlaylistResult)] = [
            ("list", .snapshot(snapshot(count: 60, current: 12))),
            ("truncated", .snapshot(snapshot(count: 60, first: 101, total: 2500, current: 112))),
            ("footer", .snapshot(snapshot(count: 8, first: 101, total: 2500, current: 112))), ("none", .noPlaylist), ("denied", .denied), ("failed", .failed),
        ]
        for (name, result) in cases {
            for clear in [false, true] {
                for dark in [true, false] {
                    try render(result, name: name, clear: clear, dark: dark, dir: dir)
                }
            }
        }
        let loading = PlaylistView(frame: NSRect(x: 0, y: 0, width: 340, height: 200))
        loading.showLoading()
        loading.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(loading.bitmapImageRepForCachingDisplay(in: loading.bounds))
        loading.cacheDisplay(in: loading.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(dir)/loading.png"))
    }
}
