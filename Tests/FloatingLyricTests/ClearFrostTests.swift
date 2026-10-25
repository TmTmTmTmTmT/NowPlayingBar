import AppKit
import Testing
@testable import FloatingLyric

@MainActor
struct ClearFrostTests {
    @Test func finalConstant() {
        let f = ClearFrost.final
        #expect(f.material == .hudWindow)
        #expect(f.blurAlpha == 0.45)
        #expect(f.dimAlpha == 0.18)
        #expect(f.tintAlpha == 0)
    }

    @Test func resolvedGlassValues() {
        let blur = GlassAppearance.resolved(isClear: true, noBlur: false)
        #expect(blur.isClear && !blur.blurHidden && blur.solidElements)
        #expect(blur.blurMaterial == .hudWindow && blur.blurOpacity == 0.45)
        #expect(blur.dimAlpha == 0.18 && blur.glassTintAlpha == 0)
        #expect(blur.pinnedDark == true)
        let plain = GlassAppearance.resolved(isClear: true, noBlur: true)
        #expect(plain.isClear && plain.blurHidden && plain.pinnedDark == true)
        #expect(GlassAppearance.resolved(isClear: false, noBlur: false) == .regular)
        #expect(GlassAppearance.resolved(isClear: false, noBlur: true).pinnedDark == true)
        #expect(GlassAppearance.regular.pinnedDark == true)
    }

    @Test func allGlassAlwaysPinnedDark() {
        #expect(GlassAppearance.alwaysDark)
        #expect(GlassAppearance.resolved(isClear: true, noBlur: false).pinnedDark == true)
        #expect(GlassAppearance.resolved(isClear: false, noBlur: false).pinnedDark == true)
    }

    @Test func lyricsHDRModeSelection() {
        let clearBlur = GlassAppearance.resolved(isClear: true, noBlur: false)
        let clearPlain = GlassAppearance.resolved(isClear: true, noBlur: true)
        #expect(LyricsView.hdrMode(for: clearPlain) == .plainClear)
        #expect(LyricsView.hdrMode(for: clearBlur) == .clearFrost)
        #expect(LyricsView.hdrMode(for: .regular) == .standard)
    }

    @Test func glassEqualityIncludesNewFields() {
        let a = GlassAppearance(isClear: true, blurHidden: false, blurOpacity: 0.58, pinnedDark: nil, solidElements: true)
        var b = a
        #expect(a == b)
        #expect(a.blurMaterial == .menu && a.dimAlpha == 0 && a.glassTintAlpha == 0)
        b.blurMaterial = .hudWindow
        #expect(a != b)
        b = a; b.dimAlpha = 0.1
        #expect(a != b)
        b = a; b.glassTintAlpha = 0.1
        #expect(a != b)
        #expect(GlassAppearance.regular.dimAlpha == 0 && GlassAppearance.regular.glassTintAlpha == 0)
    }

    private func makeChrome() -> PanelChrome {
        _ = NSApplication.shared
        return PanelChrome(lyricsView: LyricsView(preferences: LyricPreferences(defaults: UserDefaults(suiteName: "ClearFrostChrome-\(UUID().uuidString)")!)),
                           playlistView: PlaylistView(frame: .zero))
    }

    private func glass(clear: Bool, blurHidden: Bool, dim: CGFloat, tint: CGFloat) -> GlassAppearance {
        GlassAppearance(isClear: clear, blurHidden: blurHidden, blurOpacity: 0.6, blurMaterial: .hudWindow,
                        dimAlpha: dim, glassTintAlpha: tint, pinnedDark: true, solidElements: true)
    }

    @Test func chromeFrostLayersMatchGlassFrameAndRadius() {
        let chrome = makeChrome()
        chrome.frame = NSRect(x: 0, y: 0, width: 320, height: 140)
        chrome.layoutSubtreeIfNeeded()
        for placement in [LyricPreferences.Placement.floating, .belowCard, .belowMenuBar] {
            chrome.configure(placement: placement, tabsAvailable: false)
            chrome.layoutSubtreeIfNeeded()
            let expected = chrome.bounds
            let r = PanelGeometry.cornerRadius(placement)
            #expect(chrome.blurViewForTesting.frame == expected)
            #expect(chrome.dimViewForTesting.frame == expected)
            #expect(chrome.blurViewForTesting.layer?.cornerRadius == r)
            #expect(chrome.dimViewForTesting.layer?.cornerRadius == r)
            #expect(chrome.glassForTesting.cornerRadius == r)
        }
        chrome.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        chrome.layoutSubtreeIfNeeded()
        #expect(chrome.blurViewForTesting.frame == chrome.bounds)
    }

    @Test func chromePinsDarkAquaForRegularAndClear() {
        let chrome = makeChrome()
        chrome.apply(glass: .regular)
        #expect(chrome.appearance?.name == .darkAqua)
        chrome.apply(glass: GlassAppearance.resolved(isClear: true, noBlur: false))
        #expect(chrome.appearance?.name == .darkAqua)
    }

    @Test func chromeClearBlurOnAppliesDim() {
        let chrome = makeChrome()
        chrome.apply(glass: GlassAppearance.resolved(isClear: true, noBlur: false))
        #expect(chrome.blurViewForTesting.material == .hudWindow)
        #expect(chrome.blurViewForTesting.alphaValue == 0.45)
        #expect(chrome.blurViewForTesting.isHidden == false)
        #expect(chrome.dimViewForTesting.isHidden == false)
        #expect(chrome.dimViewForTesting.alphaValue == 0.18)
        #expect(chrome.glassForTesting.tintColor == nil)
        // A host-supplied tint still applies under Clear + blur.
        chrome.apply(glass: glass(clear: true, blurHidden: false, dim: 0, tint: 0.1))
        #expect(chrome.dimViewForTesting.isHidden == true)
        #expect(chrome.glassForTesting.tintColor != nil)
    }

    @Test func chromeRegularOrNoBlurIgnoresDimAndTint() {
        let chrome = makeChrome()
        chrome.apply(glass: glass(clear: false, blurHidden: true, dim: 0.18, tint: 0))
        #expect(chrome.dimViewForTesting.isHidden == true)
        #expect(chrome.glassForTesting.tintColor == nil)
        chrome.apply(glass: glass(clear: true, blurHidden: true, dim: 0.18, tint: 0))
        #expect(chrome.dimViewForTesting.isHidden == true)
        #expect(chrome.glassForTesting.tintColor == nil)
    }

    @Test func freshViewsReleaseWithoutCrash() {
        _ = NSApplication.shared
        // F13: no configure/setTab/start calls before release.
        do {
            let defaults = UserDefaults(suiteName: "ReleaseLyrics-\(UUID().uuidString)")!
            let v = LyricsView(preferences: LyricPreferences(defaults: defaults))
            #expect(v.isDriverRunning == false)
        }
        do {
            let defaults = UserDefaults(suiteName: "ReleaseChrome-\(UUID().uuidString)")!
            let chrome = PanelChrome(lyricsView: LyricsView(preferences: LyricPreferences(defaults: defaults)),
                                     playlistView: PlaylistView(frame: .zero))
            _ = chrome
        }
    }
}
