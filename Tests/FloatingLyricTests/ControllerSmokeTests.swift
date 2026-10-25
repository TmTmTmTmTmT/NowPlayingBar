import AppKit
import Testing
@testable import FloatingLyric

/// Builds the controller and its panels without ordering anything on screen and
/// calls every public method; passes when nothing crashes. Synthetic data only.
@MainActor
@Suite struct ControllerSmokeTests {
    private static let screen = ScreenInfo(id: "1", frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                           visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875))

    private func makeController(placement: LyricPreferences.Placement,
                                statusItem: @escaping () -> NSRect? = { NSRect(x: 600, y: 876, width: 200, height: 24) })
        -> (FloatingLyricController, LyricPreferences, URL) {
        _ = NSApplication.shared
        let suite = "FloatingLyricSmoke-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = LyricPreferences(defaults: defaults)
        prefs.enabled = true
        prefs.placement = placement
        let emptyCache = FileManager.default.temporaryDirectory.appendingPathComponent("lyric-smoke-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: emptyCache, withIntermediateDirectories: true)
        let provider = MusicCacheLyricsProvider(cacheDirectory: emptyCache, pollInterval: 0.05, giveUpAfter: 0.1)
        let host = LyricHost(seek: { _ in }, statusItemFrame: statusItem)
        let c = FloatingLyricController(host: host, preferences: prefs, lyricsProvider: provider)
        c.screensProvider = { [Self.screen] }
        c.suppressWindowOrdering = true
        return (c, prefs, emptyCache)
    }

    private func exercise(_ c: FloatingLyricController, prefs: LyricPreferences) {
        let music = TrackRef(title: "Synthetic Title", artist: "Synthetic Artist", album: nil, duration: 0,
                             sourceBundleID: "com.apple.Music")
        let now = Date()
        c.apply(glass: .regular)
        c.update(track: music)
        c.update(timeline: PlaybackTimeline(elapsed: 5, timestamp: now, rate: 1, duration: 200, isPlaying: true))
        var withDuration = music
        withDuration.duration = 200
        c.update(track: withDuration)
        c.apply(glass: GlassAppearance(isClear: true, blurHidden: false, blurOpacity: 0.58, pinnedDark: true, solidElements: true))
        let card = NSWindow(contentRect: NSRect(x: 500, y: 700, width: 360, height: 160), styleMask: .borderless,
                            backing: .buffered, defer: true)
        c.cardWillShow(frame: card.frame, cardWindow: card)
        c.cardWillHide()
        c.cardDidHide()
        c.statusItemDidMove()
        prefs.lastTab = .playlist
        c.preferencesDidChange()
        c.update(timeline: PlaybackTimeline(elapsed: 9, timestamp: now, rate: 0, duration: 200, isPlaying: false))
        c.update(track: TrackRef(title: "Other", artist: nil, album: nil, duration: 100, sourceBundleID: "com.spotify.client"))
        c.update(timeline: PlaybackTimeline(elapsed: 1, timestamp: now, rate: 1, duration: 100, isPlaying: true))
        c.update(track: nil)
        prefs.enabled = false
        c.preferencesDidChange()
        prefs.enabled = true
        c.preferencesDidChange()
    }

    @Test func publicAPISequenceDoesNotCrash() {
        for placement in LyricPreferences.Placement.allCases {
            let (c, prefs, dir) = makeController(placement: placement)
            defer { try? FileManager.default.removeItem(at: dir) }
            exercise(c, prefs: prefs)
            // Switch placements on the same instance as well.
            for p in LyricPreferences.Placement.allCases {
                prefs.placement = p
                c.preferencesDidChange()
            }
        }
    }

    @Test func chromeSwitchesTabsAndCornerRadius() {
        _ = NSApplication.shared
        let chrome = PanelChrome(lyricsView: LyricsView(preferences: LyricPreferences(defaults: UserDefaults(suiteName: "FloatingLyricChrome-\(UUID().uuidString)")!)),
                                 playlistView: PlaylistView(frame: .zero))
        chrome.configure(placement: .floating, tabsAvailable: true)
        chrome.setTab(.playlist, animated: false)
        #expect(chrome.tab == .playlist)
        #expect(chrome.playlistView.isHidden == false)
        #expect(chrome.lyricsView.isHidden)
        // No tabs in the menu bar strip: forced back to lyrics.
        chrome.configure(placement: .belowMenuBar, tabsAvailable: true)
        #expect(chrome.tab == .lyrics)
    }

    private func playing(_ c: FloatingLyricController) {
        c.update(track: TrackRef(title: "Synthetic Title", artist: "Synthetic Artist", album: nil, duration: 200,
                                 sourceBundleID: "com.apple.Music"))
        c.update(timeline: PlaybackTimeline(elapsed: 5, timestamp: Date(), rate: 1, duration: 200, isPlaying: true))
    }

    @Test func menuBarStripDropsUnderCardFollowsItAndReturns() {
        let (c, _, dir) = makeController(placement: .belowMenuBar)
        defer { try? FileManager.default.removeItem(at: dir) }
        playing(c)
        let home = c.panelFrameForTesting
        #expect(c.isPanelShownForTesting)
        let card = NSWindow(contentRect: NSRect(x: 500, y: 700, width: 360, height: 160), styleMask: .borderless,
                            backing: .buffered, defer: true)
        c.cardWillShow(frame: card.frame, cardWindow: card)
        let docked = c.panelFrameForTesting!
        #expect(docked.width == 360)
        #expect(abs(docked.maxY - 692) < 0.01)
        #expect(docked.minX == 500)
        // The host moves the card without cardWillShow and only notifies the widget move.
        card.setFrameOrigin(NSPoint(x: 540, y: 690))
        c.statusItemDidMove()
        #expect(c.panelFrameForTesting!.minX == 540)
        #expect(abs(c.panelFrameForTesting!.maxY - 682) < 0.01)
        c.cardWillHide()
        #expect(c.panelFrameForTesting == home)
        // Rapid reopen/close always lands on the state's frame.
        c.cardWillShow(frame: card.frame, cardWindow: card)
        c.cardWillHide()
        c.cardWillShow(frame: card.frame, cardWindow: card)
        c.cardWillHide()
        c.cardDidHide()
        #expect(c.panelFrameForTesting == home)
    }

    @Test func menuBarStripWaitsForAValidStatusItemFrame() {
        var item = NSRect(x: 0, y: 0, width: 200, height: 24)         // not laid out yet
        let (c, _, dir) = makeController(placement: .belowMenuBar, statusItem: { item })
        defer { try? FileManager.default.removeItem(at: dir) }
        playing(c)
        #expect(!c.isPanelShownForTesting)
        item = NSRect(x: 600, y: 876, width: 200, height: 24)
        c.statusItemDidMove()
        #expect(c.isPanelShownForTesting)
        #expect(c.panelFrameForTesting!.maxY < 876)
    }

    @Test func menuBarStripDocksUnderOpenCardWithoutAStatusItemFrame() {
        var item: NSRect? = NSRect(x: 0, y: -11, width: 200, height: 24)
        let (c, _, dir) = makeController(placement: .belowMenuBar, statusItem: { item })
        defer { try? FileManager.default.removeItem(at: dir) }
        playing(c)
        #expect(!c.isPanelShownForTesting)
        let card = NSWindow(contentRect: NSRect(x: 500, y: 700, width: 360, height: 160), styleMask: .borderless,
                            backing: .buffered, defer: true)
        c.cardWillShow(frame: card.frame, cardWindow: card)
        #expect(c.isPanelShownForTesting)
        #expect(c.panelFrameForTesting!.width == 360)
        #expect(abs(c.panelFrameForTesting!.maxY - 692) < 0.01)
        // No valid widget frame to return to: the strip leaves with the card.
        c.cardWillHide()
        #expect(!c.isPanelShownForTesting)
        c.cardDidHide()
        // With a valid frame it slides back up instead.
        item = NSRect(x: 600, y: 876, width: 200, height: 24)
        c.statusItemDidMove()
        c.cardWillShow(frame: card.frame, cardWindow: card)
        c.cardWillHide()
        #expect(c.isPanelShownForTesting)
        #expect(c.panelFrameForTesting!.width == 320)
    }

    @Test func forcedCardAttachmentOverridesAndRestores() {
        let (c, prefs, dir) = makeController(placement: .floating)
        defer { try? FileManager.default.removeItem(at: dir) }
        prefs.enabled = false
        c.preferencesDidChange()
        playing(c)
        #expect(!c.isPanelShownForTesting)
        let card = NSWindow(contentRect: NSRect(x: 500, y: 700, width: 360, height: 160), styleMask: .borderless,
                            backing: .buffered, defer: true)
        c.cardWillShow(frame: card.frame, cardWindow: card)
        c.setForcedCardAttachment(true)
        #expect(c.isPanelShownForTesting)
        #expect(c.panelFrameForTesting!.width == 360)             // attached under the card
        #expect(prefs.enabled == false && prefs.placement == .floating)   // saved values untouched
        // Paused for a long time: still shown while forced.
        c.update(timeline: PlaybackTimeline(elapsed: 9, timestamp: Date(), rate: 0, duration: 200, isPlaying: false))
        #expect(c.isPanelShownForTesting)
        c.setForcedCardAttachment(false)
        #expect(!c.isPanelShownForTesting)                        // user setting (off) is back
    }

    @Test func clickDragDiscrimination() {
        let o = CGPoint(x: 10, y: 10)
        #expect(!LyricsView.isDrag(from: o, to: CGPoint(x: 13, y: 10)))
        #expect(!LyricsView.isDrag(from: o, to: CGPoint(x: 14, y: 10)))     // exactly 4 pt: still a click
        #expect(LyricsView.isDrag(from: o, to: CGPoint(x: 14.5, y: 10)))
        #expect(LyricsView.isDrag(from: o, to: CGPoint(x: 13, y: 13)))      // diagonal 4.24 pt
    }

    @Test func clickToSeekGatesWindowDraggingFromLyrics() {
        let suite = "FloatingLyricClick-\(UUID().uuidString)"
        let prefs = LyricPreferences(defaults: UserDefaults(suiteName: suite)!)
        let view = LyricsView(preferences: prefs)
        #expect(view.mouseDownCanMoveWindow)                    // off (default): window drags from anywhere
        prefs.clickToSeek = true
        #expect(view.mouseDownCanMoveWindow)                    // no document yet: still draggable
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        view.show(document: LyricsDocument(timing: .line, language: nil,
                                           lines: [LyricLine(begin: 1, end: 2, key: nil, agent: nil,
                                                             words: [], background: [], translation: nil,
                                                             transliteration: nil)]), emptyState: .none)
        #expect(!view.mouseDownCanMoveWindow)                   // on: the view takes presses itself
    }
}
