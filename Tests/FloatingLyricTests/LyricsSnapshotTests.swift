import AppKit
import Testing
@testable import FloatingLyric

/// Writes PNGs of `LyricsView` for eyeballing. Skipped unless `LYRIC_SNAPSHOT_DIR` is set.
/// Synthetic text only.
@MainActor
@Suite struct LyricsSnapshotTests {
    private static let vocabulary = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]

    private static func words(_ texts: [String], from start: TimeInterval, each: TimeInterval) -> [LyricWord] {
        texts.enumerated().map { i, t in
            LyricWord(text: t, begin: start + Double(i) * each, end: start + Double(i + 1) * each,
                      trailingSpace: i < texts.count - 1)
        }
    }

    static func makeDocument() -> LyricsDocument {
        var lines: [LyricLine] = []
        func add(_ begin: TimeInterval, _ texts: [String], agent: String = "v1", bg: [String] = [], each: TimeInterval = 0.8) {
            let w = words(texts, from: begin, each: each)
            let b = words(bg, from: begin + 0.5, each: each)
            lines.append(LyricLine(begin: begin, end: w.last!.end, key: nil, agent: agent, words: w, background: b,
                                   translation: nil, transliteration: nil))
        }
        add(6,  ["alpha", "beta", "gamma", "delta"])
        add(10, ["epsilon", "zeta", "eta"], agent: "v2")
        add(14, ["theta", "alpha", "beta", "gamma"], bg: ["delta", "epsilon"])
        add(18, ["zeta", "eta", "theta", "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "alpha",
                 "beta", "gamma", "delta"], each: 0.5)
        add(26, ["가나다", "라마바", "사아자", "차카타"])
        add(30, ["beta", "gamma", "delta"])
        add(34, ["epsilon", "zeta", "eta", "theta"])
        // 10 s instrumental gap before the next line.
        add(48, ["alpha", "beta", "gamma"])
        add(52, ["delta", "epsilon", "zeta", "eta"], agent: "v2")
        add(56, ["theta", "alpha", "beta"])
        add(60, ["gamma", "delta", "epsilon"])
        add(64, ["zeta", "eta", "theta", "alpha"])
        // One word group of three glued spans (longest 4 s); the last span ends with a space.
        let long = [LyricWord(text: "가나", begin: 70, end: 71, trailingSpace: false),
                    LyricWord(text: "다라마바", begin: 71, end: 75, trailingSpace: false),
                    LyricWord(text: "사아", begin: 75, end: 76, trailingSpace: true),
                    LyricWord(text: "beta", begin: 76, end: 76.8, trailingSpace: false)]
        lines.append(LyricLine(begin: 70, end: 76.8, key: nil, agent: "v1", words: long, background: [],
                               translation: nil, transliteration: nil))
        add(78, ["gamma", "delta"])
        return LyricsDocument(timing: .word, language: nil, lines: lines)
    }

    private func render(glass: GlassAppearance, dark: Bool, at t: TimeInterval, to url: URL) throws {
        _ = NSApplication.shared
        let size = NSSize(width: 420, height: LyricsView.preferredHeight(lines: 5, textSize: .medium))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(white: dark ? 0.22 : 0.82, alpha: 1).cgColor
        window.contentView = backdrop
        let view = LyricsView(preferences: LyricPreferences(defaults: UserDefaults(suiteName: "lyric.snap.\(UUID())")!))
        view.frame = backdrop.bounds
        backdrop.addSubview(view)
        view.placement = .floating
        view.apply(glass: glass)
        view.show(document: Self.makeDocument(), emptyState: .none)
        view.update(timeline: PlaybackTimeline(elapsed: t, timestamp: Date(), rate: 1, duration: 300, isPlaying: false))
        backdrop.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.update(timeline: PlaybackTimeline(elapsed: t + 0.01, timestamp: Date(), rate: 1, duration: 300, isPlaying: false))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let rep = try #require(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    @Test func writeSnapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["LYRIC_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let clear = GlassAppearance(isClear: true, blurHidden: true, blurOpacity: 0.58, pinnedDark: nil, solidElements: true)
        let times: [(String, TimeInterval)] = [("midword", 15.3), ("between", 28.2), ("interlude", 42), ("emph", 73.0), ("emphrise", 71.6), ("emphhold", 74.6)]
        for (palette, glass) in [("regular", GlassAppearance.regular), ("clear", clear)] {
            for dark in [true, false] {
                var g = glass
                if palette == "clear" { g.pinnedDark = dark }
                for (name, t) in times {
                    let file = "\(palette)-\(dark ? "dark" : "light")-\(name).png"
                    try render(glass: g, dark: dark, at: t, to: URL(fileURLWithPath: dir).appendingPathComponent(file))
                }
            }
        }
    }
}
