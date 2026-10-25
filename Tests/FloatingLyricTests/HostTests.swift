import Foundation
import Testing
@testable import FloatingLyric

@Suite struct PlaybackTimelineTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func advancesWhilePlaying() {
        let tl = PlaybackTimeline(elapsed: 10, timestamp: t0, rate: 1, duration: 200, isPlaying: true)
        #expect(abs(tl.position(at: t0.addingTimeInterval(2.5)) - 12.5) < 1e-9)
    }

    @Test func holdsWhenPausedOrRateZero() {
        let paused = PlaybackTimeline(elapsed: 10, timestamp: t0, rate: 1, duration: 200, isPlaying: false)
        let stopped = PlaybackTimeline(elapsed: 10, timestamp: t0, rate: 0, duration: 200, isPlaying: true)
        #expect(paused.position(at: t0.addingTimeInterval(5)) == 10)
        #expect(stopped.position(at: t0.addingTimeInterval(5)) == 10)
    }

    @Test func clampsToTrack() {
        let tl = PlaybackTimeline(elapsed: 198, timestamp: t0, rate: 1, duration: 200, isPlaying: true)
        #expect(tl.position(at: t0.addingTimeInterval(10)) == 200)
        #expect(tl.position(at: t0.addingTimeInterval(-500)) == 0)
    }
}

@Suite struct LyricPreferencesTests {
    private func fresh() -> LyricPreferences {
        let name = "lyric.test.\(UUID().uuidString)"
        return LyricPreferences(defaults: UserDefaults(suiteName: name)!)
    }

    @Test func defaults() {
        let p = fresh()
        #expect(p.enabled == false)
        #expect(p.placement == .belowCard)
        #expect(p.context == .around)
        #expect(p.lines == 3)
        #expect(p.floatingWidth == 420)
        #expect(p.blurInactive == true)
    }

    @Test func linesAreClamped() {
        let p = fresh()
        p.lines = 0
        #expect(p.lines == 1)
        p.lines = 40
        #expect(p.lines == 9)
    }

    private func suite(_ configure: (UserDefaults) -> Void) -> UserDefaults {
        let d = UserDefaults(suiteName: "lyric.test.\(UUID().uuidString)")!
        configure(d)
        return d
    }

    @Test func linesMigrationKeepsNewKey() {
        let d = suite { $0.set(7, forKey: "lyric.lines"); $0.set(4, forKey: "lyric.lines.card") }
        #expect(LyricPreferences(defaults: d).lines == 7)
    }

    @Test func linesMigrationTakesOldKeyOfSavedPlacement() {
        let d = suite {
            $0.set(LyricPreferences.Placement.belowMenuBar.rawValue, forKey: "lyric.placement")
            $0.set(5, forKey: "lyric.lines.floating"); $0.set(4, forKey: "lyric.lines.card")
            $0.set(2, forKey: "lyric.lines.menubar")
        }
        let p = LyricPreferences(defaults: d)
        #expect(p.lines == 2)
        #expect(d.integer(forKey: "lyric.lines.card") == 4)         // old keys are kept
        p.lines = 6
        #expect(LyricPreferences(defaults: d).lines == 6)           // migrated once, not re-derived
    }

    @Test func linesMigrationDefaultsToThree() {
        let d = suite { $0.set(LyricPreferences.Placement.floating.rawValue, forKey: "lyric.placement") }
        #expect(LyricPreferences(defaults: d).lines == 3)
    }

    @Test func widthSnapsToPreset() {
        let p = fresh()
        p.floatingWidth = 500
        #expect(p.floatingWidth == 560)
    }

    @Test func originRoundTrip() {
        let p = fresh()
        #expect(p.floatingOrigin(screenID: "A") == nil)
        p.setFloatingOrigin(CGPoint(x: 12, y: 34), screenID: "A")
        #expect(p.floatingOrigin(screenID: "A") == CGPoint(x: 12, y: 34))
    }
}
