import AppKit
import Testing
@testable import FloatingLyric

/// FIX_GUIDE F9 (floating position), F10 (non-Music hides the panel) and PLAN 12.11
/// (paused hide delay) through the controller. Synthetic data only.
@MainActor
@Suite struct FloatingPositionTests {
    private static let screen = ScreenInfo(id: "1", frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                           visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875))

    private func make(placement: LyricPreferences.Placement) -> (FloatingLyricController, LyricPreferences, URL) {
        _ = NSApplication.shared
        let suite = "FloatingLyricPosition-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = LyricPreferences(defaults: defaults)
        prefs.enabled = true
        prefs.placement = placement
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("lyric-pos-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let provider = MusicCacheLyricsProvider(cacheDirectory: cache, pollInterval: 0.05, giveUpAfter: 0.1)
        let host = LyricHost(seek: { _ in }, statusItemFrame: { NSRect(x: 600, y: 876, width: 200, height: 24) })
        let c = FloatingLyricController(host: host, preferences: prefs, lyricsProvider: provider)
        c.screensProvider = { [Self.screen] }
        c.suppressWindowOrdering = true
        return (c, prefs, cache)
    }

    private func play(_ c: FloatingLyricController, source: String = "com.apple.Music") {
        c.update(track: TrackRef(title: "Synthetic Title", artist: "Synthetic Artist", album: nil, duration: 200,
                                 sourceBundleID: source))
        c.update(timeline: PlaybackTimeline(elapsed: 5, timestamp: Date(), rate: 1, duration: 200, isPlaying: true))
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: UInt64((FloatingLyricPanel.Metrics.saveDebounce + 0.25) * 1e9))
    }

    @Test func clickThroughAppliesToFloatingAndBelowMenuBarOnly() {
        _ = NSApplication.shared
        let chrome = PanelChrome(lyricsView: LyricsView(preferences: LyricPreferences(defaults: UserDefaults(suiteName: "FloatingLyricPanelCT-\(UUID().uuidString)")!)),
                                 playlistView: PlaylistView(frame: .zero))
        let panel = FloatingLyricPanel(chrome: chrome)
        panel.suppressOrdering = true
        for (p, expectOn) in [(LyricPreferences.Placement.floating, true), (.belowMenuBar, true), (.belowCard, false)] {
            panel.apply(placement: p, locked: false, clickThrough: true)
            #expect(panel.ignoresMouseEvents == expectOn)
            panel.apply(placement: p, locked: false, clickThrough: false)
            #expect(panel.ignoresMouseEvents == false)
        }
    }

    // MARK: F9

    @Test func programmaticMovesDoNotSaveButExternalOnesDo() async {
        _ = NSApplication.shared
        let chrome = PanelChrome(lyricsView: LyricsView(preferences: LyricPreferences(defaults: UserDefaults(suiteName: "FloatingLyricPanelMove-\(UUID().uuidString)")!)),
                                 playlistView: PlaylistView(frame: .zero))
        let panel = FloatingLyricPanel(chrome: chrome)
        panel.suppressOrdering = true
        panel.apply(placement: .floating, locked: false, clickThrough: false)
        var saved: [NSRect] = []
        panel.onUserMoved = { saved.append($0) }

        panel.setPanelFrame(NSRect(x: 100, y: 300, width: 420, height: 200), animated: false)
        panel.slide(to: NSRect(x: 150, y: 320, width: 420, height: 200))
        await settle()
        #expect(saved.isEmpty)

        panel.setFrameOrigin(NSPoint(x: 400, y: 500))                 // e.g. a window-server drag
        await settle()
        #expect(saved.count == 1)
        #expect(saved.first?.origin == NSPoint(x: 400, y: 500))
    }

    @Test func leavingFloatingSavesAtOnceAndReturningRestores() {
        let (c, prefs, dir) = make(placement: .floating)
        defer { try? FileManager.default.removeItem(at: dir) }
        play(c)
        #expect(c.isPanelShownForTesting)
        let panel = c.panelForTesting!
        panel.setFrameOrigin(NSPoint(x: 300, y: 400))
        let topLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)

        prefs.placement = .belowCard                                   // no debounce wait: saved on leaving
        c.preferencesDidChange()
        #expect(prefs.floatingOrigin(screenID: "1") == topLeft)
        #expect(!c.isPanelShownForTesting)

        prefs.setFloatingOrigin(CGPoint(x: 50, y: 800), screenID: "1")  // older value must lose to this session's spot
        prefs.placement = .floating
        c.preferencesDidChange()
        #expect(c.isPanelShownForTesting)
        let back = c.panelForTesting!.frame
        #expect(CGPoint(x: back.minX, y: back.maxY) == topLeft)
    }

    @Test func savedOriginIsUsedWithoutMemory() {
        let (c, prefs, dir) = make(placement: .floating)
        defer { try? FileManager.default.removeItem(at: dir) }
        prefs.setFloatingOrigin(CGPoint(x: 200, y: 700), screenID: "1")
        play(c)
        let f = c.panelForTesting!.frame
        #expect(CGPoint(x: f.minX, y: f.maxY) == CGPoint(x: 200, y: 700))
    }

    // MARK: F10

    @Test func nonMusicSourceHidesThePanelAndMusicBringsItBack() {
        for placement in [LyricPreferences.Placement.floating] {
            let (c, _, dir) = make(placement: placement)
            defer { try? FileManager.default.removeItem(at: dir) }
            play(c)
            #expect(c.isPanelShownForTesting)
            play(c, source: "com.spotify.client")
            #expect(!c.isPanelShownForTesting)
            play(c)
            #expect(c.isPanelShownForTesting)
        }
    }

    @Test func nonMusicSourceHidesTheForcedCardAttachmentToo() {
        let (c, _, dir) = make(placement: .floating)
        defer { try? FileManager.default.removeItem(at: dir) }
        let card = NSWindow(contentRect: NSRect(x: 500, y: 700, width: 360, height: 160), styleMask: .borderless,
                            backing: .buffered, defer: true)
        c.cardWillShow(frame: card.frame, cardWindow: card)
        c.setForcedCardAttachment(true)
        play(c)
        #expect(c.isPanelShownForTesting)
        play(c, source: "com.apple.Safari")
        #expect(!c.isPanelShownForTesting)
        play(c)
        #expect(c.isPanelShownForTesting)
    }

    // MARK: PLAN 12.11

    @Test func changingTheDelayWhilePausedRecomputesTheRemainingTime() async {
        let (c, prefs, dir) = make(placement: .floating)
        defer { try? FileManager.default.removeItem(at: dir) }
        prefs.pausedHideDelay = 5
        play(c)
        c.update(timeline: PlaybackTimeline(elapsed: 9, timestamp: Date(), rate: 0, duration: 200, isPlaying: false))
        #expect(c.isPanelShownForTesting)
        try? await Task.sleep(nanoseconds: 5_400_000_000)
        #expect(!c.isPanelShownForTesting)                              // 5 s passed
        prefs.pausedHideDelay = 60                                      // longer: shown again for the rest
        c.preferencesDidChange()
        #expect(c.isPanelShownForTesting)
        prefs.pausedHideDelay = 5                                       // already past: hidden at once
        c.preferencesDidChange()
        #expect(!c.isPanelShownForTesting)
    }
}
