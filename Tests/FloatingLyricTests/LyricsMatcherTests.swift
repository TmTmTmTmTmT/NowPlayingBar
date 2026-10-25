import Testing
import Foundation
@testable import FloatingLyric

struct LyricsMatcherTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func cand(_ name: String, artist: String = "A", album: String = "B",
                      duration: TimeInterval = 200, at: Date = t0, ttml: String = "x") -> CacheCandidate {
        CacheCandidate(name: name, artistName: artist, albumName: album,
                       duration: duration, cachedAt: at, ttml: ttml)
    }

    private func track(_ title: String, artist: String? = "A", album: String? = "B",
                       duration: TimeInterval = 200) -> TrackRef {
        TrackRef(title: title, artist: artist, album: album, duration: duration,
                 sourceBundleID: "com.apple.Music")
    }

    @Test func nfcAndNfdMatch() {
        let nfd = "\u{110B}\u{1161}\u{110B}\u{1175}"   // decomposed jamo
        let nfc = nfd.precomposedStringWithCanonicalMapping
        #expect(Array(nfd.unicodeScalars) != Array(nfc.unicodeScalars))
        let r = LyricsMatcher.pick(from: [cand(nfc)], for: track(nfd), trackStart: nil)
        #expect(r != nil)
    }

    @Test func featTailAndBracketsStripped() {
        #expect(LyricsMatcher.normalize("Song  Name (feat. Someone)") == "song name")
        #expect(LyricsMatcher.normalize("Song Name [Remastered]") == "song name")
        #expect(LyricsMatcher.normalize("Song (with X) [Live]") == "song")
        #expect(LyricsMatcher.normalize("Song (Acoustic)") == "song (acoustic)")
        let r = LyricsMatcher.pick(from: [cand("Song (feat. Q)")], for: track("SONG"), trackStart: nil)
        #expect(r != nil)
    }

    @Test func artistMismatchStillMatches() {
        let r = LyricsMatcher.pick(from: [cand("Song", artist: "아이유", album: "Z")],
                                   for: track("Song", artist: "IU"), trackStart: nil)
        #expect(r != nil)
    }

    @Test func durationOutsideTwoSecondsRejected() {
        #expect(LyricsMatcher.pick(from: [cand("Song", duration: 202.5)], for: track("Song"), trackStart: nil) == nil)
        #expect(LyricsMatcher.pick(from: [cand("Song", duration: 198.5)], for: track("Song"), trackStart: nil) != nil)
    }

    @Test func timePathFallback() {
        let c = cand("Localized", duration: 200.3, at: Self.t0)
        let start = Self.t0.addingTimeInterval(4)
        #expect(LyricsMatcher.pick(from: [c], for: track("Other"), trackStart: start) != nil)
        // too far in time
        #expect(LyricsMatcher.pick(from: [c], for: track("Other"), trackStart: Self.t0.addingTimeInterval(45)) == nil)
        // duration off by more than 0.5s
        let d = cand("Localized", duration: 201, at: Self.t0)
        #expect(LyricsMatcher.pick(from: [d], for: track("Other"), trackStart: start) == nil)
        // no start time -> no fallback
        #expect(LyricsMatcher.pick(from: [c], for: track("Other"), trackStart: nil) == nil)
    }

    @Test func timeWindowLeansEarlyForPrefetchedEntries() {
        // cachedAt - trackStart in [-30, +10]
        let c = cand("Localized", duration: 200.3, at: Self.t0)
        func hit(_ startOffset: TimeInterval) -> Bool {
            LyricsMatcher.pick(from: [c], for: track("Other"), trackStart: Self.t0.addingTimeInterval(startOffset)) != nil
        }
        #expect(hit(25))          // entry 25 s before the track start (prefetch)
        #expect(hit(30))
        #expect(!hit(31))
        #expect(hit(-10))         // entry 10 s after the start
        #expect(!hit(-11))
    }

    @Test func titlePathBeatsTimePath() {
        let byTime = cand("Different", at: Self.t0)
        let byTitle = cand("Song", at: Self.t0.addingTimeInterval(-500), ttml: "title")
        let r = LyricsMatcher.pick(from: [byTime, byTitle], for: track("Song"), trackStart: Self.t0)
        #expect(r?.ttml == "title")
    }

    @Test func tieBreakAlbumThenArtistThenNewest() {
        let old = Self.t0, mid = Self.t0.addingTimeInterval(10), new = Self.t0.addingTimeInterval(20)
        // album wins over newer
        var r = LyricsMatcher.pick(
            from: [cand("S", album: "B", at: old, ttml: "albumOld"), cand("S", album: "Other", at: new, ttml: "new")],
            for: track("S", artist: "Q"), trackStart: nil)
        #expect(r?.ttml == "albumOld")
        // artist wins when album ties
        r = LyricsMatcher.pick(
            from: [cand("S", artist: "A", at: old, ttml: "artistOld"), cand("S", artist: "Z", at: new, ttml: "new")],
            for: track("S", album: nil), trackStart: nil)
        #expect(r?.ttml == "artistOld")
        // newest when nothing else separates
        r = LyricsMatcher.pick(
            from: [cand("S", at: old, ttml: "old"), cand("S", at: new, ttml: "new"), cand("S", at: mid, ttml: "mid")],
            for: track("S"), trackStart: nil)
        #expect(r?.ttml == "new")
    }

    @Test func unknownDurationMatchesByTitleOnly() {
        let c = cand("Song", duration: 200)
        #expect(LyricsMatcher.pick(from: [c], for: track("Song", duration: 0), trackStart: nil) != nil)
        #expect(LyricsMatcher.pick(from: [c], for: track("Other", duration: 0), trackStart: nil) == nil)
    }

    @Test func unknownDurationSkipsTimePath() {
        // Title differs (localized): the time path needs a duration, so no match.
        let c = cand("Localized", duration: 200, at: Self.t0)
        let r = LyricsMatcher.pick(from: [c], for: track("Original", duration: 0), trackStart: Self.t0)
        #expect(r == nil)
    }

    @Test func staleSingleCandidateWithCloseDurationDoesNotMatch() {
        // F23: only the duration is close (0.1 s), cached 40 minutes before the start.
        let stale = cand("Old", duration: 200.1, at: Self.t0.addingTimeInterval(-2400))
        #expect(LyricsMatcher.pick(from: [stale], for: track("Other"), trackStart: nil) == nil)
        #expect(LyricsMatcher.pick(from: [stale], for: track("Other"), trackStart: Self.t0) == nil)
    }

    @Test func diagnosticsReportTrackStartKnown() {
        let d = LyricsMatcher.diagnostics(candidates: [], track: track("S"), trackStart: nil, launch: nil)
        #expect(d.contains("trackStartKnown=false"))
    }
}
