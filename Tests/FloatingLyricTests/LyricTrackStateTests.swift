import Foundation
import Testing
@testable import FloatingLyric

struct LyricTrackStateTests {
    private func track(_ title: String, artist: String? = "Artist", duration: TimeInterval = 200,
                       source: String = "com.apple.Music") -> TrackRef {
        TrackRef(title: title, artist: artist, album: nil, duration: duration, sourceBundleID: source)
    }

    private func doc(_ id: String?) -> LyricsDocument {
        LyricsDocument(timing: .line, language: nil, lines: [], songID: id)
    }

    @Test func keyNormalizesTitleAndArtist() {
        #expect(LyricTrackState.key(for: track("Song (feat. Guest)", artist: "ARTIST"))
                == LyricTrackState.key(for: track("song", artist: "artist")))
        #expect(LyricTrackState.key(for: track("Song")) != LyricTrackState.key(for: track("Other")))
        #expect(LyricTrackState.key(for: track("Song", duration: 0)) == LyricTrackState.key(for: track("Song", duration: 200)))
        #expect(LyricTrackState.key(for: track("Song", artist: nil)) == LyricTrackState.key(for: track("Song", artist: "")))
    }

    @Test func durationBecameKnown() {
        #expect(LyricTrackState.durationBecameKnown(old: track("A", duration: 0), new: track("A", duration: 180)))
        #expect(!LyricTrackState.durationBecameKnown(old: track("A", duration: 180), new: track("A", duration: 181)))
        #expect(!LyricTrackState.durationBecameKnown(old: track("A", duration: 0), new: track("A", duration: 0)))
        #expect(!LyricTrackState.durationBecameKnown(old: track("A", duration: 0), new: track("B", duration: 180)))
        #expect(!LyricTrackState.durationBecameKnown(old: nil, new: track("A", duration: 180)))
    }

    @Test func trackStartFromTimeline() {
        let ts = Date(timeIntervalSince1970: 1_800_000_000)
        let playing = PlaybackTimeline(elapsed: 30, timestamp: ts, rate: 1, duration: 200, isPlaying: true)
        #expect(LyricTrackState.trackStart(timeline: playing) == ts.addingTimeInterval(-30))
        let fast = PlaybackTimeline(elapsed: 30, timestamp: ts, rate: 2, duration: 200, isPlaying: true)
        #expect(LyricTrackState.trackStart(timeline: fast) == ts.addingTimeInterval(-15))
        let paused = PlaybackTimeline(elapsed: 30, timestamp: ts, rate: 0, duration: 200, isPlaying: false)
        #expect(LyricTrackState.trackStart(timeline: paused) == ts.addingTimeInterval(-30))
    }

    @Test func trackStartNilWithoutOrWithStaleTimeline() {
        #expect(LyricTrackState.trackStart(timeline: nil) == nil)
        let ts = Date(timeIntervalSince1970: 1_800_000_000)
        let other = PlaybackTimeline(elapsed: 30, timestamp: ts, rate: 1, duration: 300, isPlaying: true)
        #expect(LyricTrackState.trackStart(timeline: other, trackDuration: 200) == nil)
        #expect(LyricTrackState.trackStart(timeline: other, trackDuration: 301) != nil)
        #expect(LyricTrackState.trackStart(timeline: other, trackDuration: 0) != nil)
    }

    @Test func visibilityRule() {
        func v(_ e: Bool, _ t: Bool, _ p: Bool, _ f: TimeInterval, music: Bool = true, delay: TimeInterval = 30) -> Bool {
            LyricTrackState.isVisible(enabled: e, hasTrack: t, isMusicSource: music, isPlaying: p,
                                      pausedFor: f, hideDelay: delay)
        }
        #expect(v(true, true, true, 0))
        #expect(v(true, true, false, 29.9))
        #expect(!v(true, true, false, 30))
        #expect(!v(false, true, true, 0))
        #expect(!v(true, false, true, 0))
        #expect(v(true, true, true, 100))      // playing wins over a stale pause clock
        // Other sources hide the panel, playing or not (FIX_GUIDE F10).
        #expect(!v(true, true, true, 0, music: false))
        #expect(!v(true, true, false, 1, music: false))
        // The delay is a parameter (PLAN 12.11).
        #expect(!v(true, true, false, 5, delay: 5))
        #expect(v(true, true, false, 59.9, delay: 60))
    }

    @Test func pausedHideDelaySnapsAndDefaults() {
        let suite = "FloatingLyricDelay-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = LyricPreferences(defaults: defaults)
        #expect(prefs.pausedHideDelay == 30)
        prefs.pausedHideDelay = 10
        #expect(prefs.pausedHideDelay == 10)
        defaults.set(44.0, forKey: "lyric.pausedHideDelay")        // stored off-grid: nearest choice
        #expect(prefs.pausedHideDelay == 30)
        defaults.set(1000.0, forKey: "lyric.pausedHideDelay")
        #expect(prefs.pausedHideDelay == 60)
        defaults.set(0.0, forKey: "lyric.pausedHideDelay")
        #expect(prefs.pausedHideDelay == 5)
        defaults.set(17.0, forKey: "lyric.pausedHideDelay")
        #expect(prefs.pausedHideDelay == 15)
    }

    @Test func relookupKeepsSameSong() {
        #expect(!LyricTrackState.shouldReplace(current: doc("1"), with: doc("1"), isRelookup: true))
        #expect(LyricTrackState.shouldReplace(current: doc("1"), with: doc("2"), isRelookup: true))
        #expect(!LyricTrackState.shouldReplace(current: doc("1"), with: nil, isRelookup: true))
        #expect(LyricTrackState.shouldReplace(current: nil, with: doc("1"), isRelookup: true))
        #expect(LyricTrackState.shouldReplace(current: nil, with: nil, isRelookup: true))
    }

    @Test func firstLookupAlwaysReplaces() {
        #expect(LyricTrackState.shouldReplace(current: doc("1"), with: doc("1"), isRelookup: false))
        #expect(LyricTrackState.shouldReplace(current: doc("1"), with: nil, isRelookup: false))
    }

    @Test func playlistTabOnlyForMusic() {
        #expect(LyricTrackState.playlistTabAvailable(sourceBundleID: "com.apple.Music"))
        #expect(!LyricTrackState.playlistTabAvailable(sourceBundleID: "com.spotify.client"))
        #expect(!LyricTrackState.playlistTabAvailable(sourceBundleID: nil))
        #expect(LyricTrackState.effectiveTab(preferred: .playlist, playlistAvailable: true) == .playlist)
        #expect(LyricTrackState.effectiveTab(preferred: .playlist, playlistAvailable: false) == .lyrics)
        #expect(LyricTrackState.effectiveTab(preferred: .lyrics, playlistAvailable: true) == .lyrics)
        #expect(LyricTrackState.supportsLyrics(sourceBundleID: "com.apple.Music"))
        #expect(!LyricTrackState.supportsLyrics(sourceBundleID: "com.apple.Safari"))
    }
}

struct LyricForcedStateTests {
    @Test func forcedOverridesSavedSettings() {
        #expect(LyricTrackState.effectiveEnabled(saved: false, forcedCard: true))
        #expect(!LyricTrackState.effectiveEnabled(saved: false, forcedCard: false))
        #expect(LyricTrackState.effectiveEnabled(saved: true, forcedCard: false))
        for p in LyricPreferences.Placement.allCases {
            #expect(LyricTrackState.effectivePlacement(saved: p, forcedCard: true) == .belowCard)
            #expect(LyricTrackState.effectivePlacement(saved: p, forcedCard: false) == p)
        }
        #expect(LyricTrackState.effectivePausedFor(120, forcedCard: true) == 0)
        #expect(LyricTrackState.effectivePausedFor(120, forcedCard: false) == 120)
        #expect(LyricTrackState.effectivePausedFor(120, forcedCard: false, scrolling: true) == 0)
        #expect(LyricTrackState.effectivePausedFor(120, forcedCard: false, scrolling: false) == 120)
        #expect(LyricTrackState.effectivePausedFor(120, forcedCard: true, scrolling: false) == 0)
        #expect(LyricTrackState.isVisible(enabled: true, hasTrack: true, isMusicSource: true, isPlaying: false,
                                          pausedFor: LyricTrackState.effectivePausedFor(120, forcedCard: false, scrolling: true), hideDelay: 30))
        #expect(!LyricTrackState.isVisible(enabled: true, hasTrack: true, isMusicSource: true, isPlaying: false,
                                           pausedFor: LyricTrackState.effectivePausedFor(120, forcedCard: false, scrolling: false), hideDelay: 30))
    }

    @Test func emptyStateFromLookupResult() {
        #expect(LyricTrackState.emptyState(for: LyricsLookupResult(document: nil)) == .noLyrics)
        #expect(LyricTrackState.emptyState(for: LyricsLookupResult(document: nil, noSessionEntries: true)) == .openLyricsInMusicOnce)
        #expect(LyricsEmptyState.openLyricsInMusicOnce.message != nil)
        #expect(LyricsEmptyState.openLyricsInMusicOnce.detail != nil)
        #expect(LyricsEmptyState.noLyrics.message == "가사를 찾지 못했습니다")
        #expect(LyricsEmptyState.noLyrics.detail == "Apple Music에서 이 곡의 가사를 열면 바로 표시됩니다")
    }
}
