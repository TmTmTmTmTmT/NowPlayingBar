import Foundation
import Testing
@testable import FloatingLyric

@Suite struct LyricClockTests {
    private let t0 = Date(timeIntervalSince1970: 5_000)

    private func tl(_ elapsed: TimeInterval, at: Date, rate: Double = 1, playing: Bool = true) -> PlaybackTimeline {
        PlaybackTimeline(elapsed: elapsed, timestamp: at, rate: rate, duration: 300, isPlaying: playing)
    }

    @Test func emptyClockIsZeroAndStopped() {
        let c = LyricClock()
        #expect(c.position(at: t0) == 0)
        #expect(c.isRunning == false)
    }

    @Test func firstSampleCountsAsJump() {
        let c = LyricClock()
        #expect(c.update(timeline: tl(10, at: t0), now: t0))
    }

    @Test func negativeOffsetHoldsLyricsBack() {
        let c = LyricClock()
        c.timingOffset = -1
        c.update(timeline: tl(10, at: t0), now: t0)
        #expect(abs(c.position(at: t0.addingTimeInterval(1.5)) - 10.5) < 1e-9)
        c.timingOffset = -AtmosSetting.delay
        c.update(timeline: tl(0.5, at: t0), now: t0)
        #expect(c.position(at: t0) == 0)                       // never negative
    }

    @Test func atmosSettingOnlyOffAtThirty() {
        #expect(!AtmosSetting.isEnabled(rawValue: 30))
        #expect(AtmosSetting.isEnabled(rawValue: nil))
        #expect(AtmosSetting.isEnabled(rawValue: 10))
        #expect(AtmosSetting.isEnabled(rawValue: 20))
    }

    @Test func interpolatesBetweenSamples() {
        let c = LyricClock()
        c.update(timeline: tl(10, at: t0), now: t0)
        #expect(abs(c.position(at: t0.addingTimeInterval(1.5)) - 11.5) < 1e-9)
    }

    @Test func smallDriftIsNotAJump() {
        let c = LyricClock()
        c.update(timeline: tl(10, at: t0), now: t0)
        let now = t0.addingTimeInterval(5)
        #expect(c.update(timeline: tl(15.4, at: now), now: now) == false)
    }

    @Test func seekForwardAndBackAreJumps() {
        let c = LyricClock()
        c.update(timeline: tl(10, at: t0), now: t0)
        let n1 = t0.addingTimeInterval(2)
        #expect(c.update(timeline: tl(90, at: n1), now: n1))
        let n2 = n1.addingTimeInterval(1)
        #expect(c.update(timeline: tl(20, at: n2), now: n2))
    }

    @Test func pauseKeepsPositionAndStopsRunning() {
        let c = LyricClock()
        c.update(timeline: tl(10, at: t0), now: t0)
        let now = t0.addingTimeInterval(3)
        #expect(c.update(timeline: tl(13, at: now, playing: false), now: now) == false)
        #expect(c.isRunning == false)
        #expect(c.position(at: now.addingTimeInterval(10)) == 13)
    }

    @Test func rateZeroIsNotRunning() {
        let c = LyricClock()
        c.update(timeline: tl(10, at: t0, rate: 0), now: t0)
        #expect(c.isRunning == false)
    }

    @Test func offsetShiftsAndClamps() {
        let c = LyricClock()
        c.timingOffset = -2
        c.update(timeline: tl(1, at: t0), now: t0)
        #expect(c.position(at: t0) == 0)
        #expect(abs(c.position(at: t0.addingTimeInterval(5)) - 4) < 1e-9)
    }

    // MARK: monotonic displayed position (FIX_GUIDE F3)

    @Test func pauseSampleSlightlyBehindDoesNotMoveBackwards() {
        let c = LyricClock()
        c.update(timeline: tl(10, at: t0), now: t0)
        let now = t0.addingTimeInterval(5)                        // extrapolated: 15
        #expect(abs(c.position(at: now) - 15) < 1e-9)
        // Paused sample says the real position was 14.6 (0.4 s behind).
        #expect(c.update(timeline: tl(14.6, at: now, playing: false), now: now) == false)
        #expect(abs(c.position(at: now) - 15) < 1e-9)
        #expect(abs(c.position(at: now.addingTimeInterval(20)) - 15) < 1e-9)
    }

    @Test func resumeCatchesUpWithoutGoingBack() {
        let c = LyricClock()
        c.update(timeline: tl(10, at: t0), now: t0)
        let paused = t0.addingTimeInterval(5)
        _ = c.position(at: paused)                                 // displays 15
        c.update(timeline: tl(14.6, at: paused, playing: false), now: paused)
        let resume = paused.addingTimeInterval(10)
        c.update(timeline: tl(14.6, at: resume), now: resume)
        #expect(abs(c.position(at: resume) - 15) < 1e-9)           // held
        #expect(abs(c.position(at: resume.addingTimeInterval(0.2)) - 15) < 1e-9)
        #expect(abs(c.position(at: resume.addingTimeInterval(1)) - 15.6) < 1e-9)   // real position passed it
    }

    @Test func seekBackBeyondOneSecondAppliesImmediately() {
        let c = LyricClock()
        c.update(timeline: tl(10, at: t0), now: t0)
        let now = t0.addingTimeInterval(5)
        _ = c.position(at: now)                                    // 15
        #expect(c.update(timeline: tl(13.5, at: now, playing: false), now: now))   // 1.5 s back = seek
        #expect(abs(c.position(at: now) - 13.5) < 1e-9)
    }

    @Test func rawPositionBeyondOneSecondBackIsASeekEvenWithoutAJump() {
        let c = LyricClock()
        c.timingOffset = 0
        c.update(timeline: tl(10, at: t0), now: t0)
        _ = c.position(at: t0.addingTimeInterval(5))               // 15
        c.timingOffset = -2                                        // raw becomes 13: 2 s back
        #expect(abs(c.position(at: t0.addingTimeInterval(5)) - 13) < 1e-9)
    }

    @Test func resetStartsFromTheRealPosition() {
        let c = LyricClock()
        c.update(timeline: tl(10, at: t0), now: t0)
        let now = t0.addingTimeInterval(5)
        _ = c.position(at: now)                                    // 15
        c.update(timeline: tl(14.6, at: now, playing: false), now: now)
        c.resetDisplayedPosition()                                 // track / document changed
        #expect(abs(c.position(at: now) - 14.6) < 1e-9)
        c.clear()
        #expect(c.position(at: now) == 0)
    }
}
