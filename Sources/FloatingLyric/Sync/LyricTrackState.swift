import Foundation

/// The controller's decisions as pure functions (PLAN 11.1), so they can be
/// tested without panels, timers or a running Music.
enum LyricTrackState {
    /// Identity of a song: normalized title | artist. Duration is deliberately not part
    /// of it, because the host may report 0 right after a track change.
    static func key(for track: TrackRef) -> String {
        "\(LyricsMatcher.normalize(track.title))|\(LyricsMatcher.normalize(track.artist ?? ""))"
    }

    /// Same song as before, but the length was unknown and is known now: look again
    /// (the provider's memory cache makes a repeat cheap).
    static func durationBecameKnown(old: TrackRef?, new: TrackRef) -> Bool {
        guard let old, key(for: old) == key(for: new) else { return false }
        return old.duration <= 0 && new.duration > 0
    }

    /// Wall-clock start of the track from the latest sample: `timestamp - elapsed / rate`.
    /// Rate 0 (paused) counts the elapsed time as real time. nil without a sample, or when the
    /// sample's duration clearly belongs to another track (stale sample right after a skip).
    static func trackStart(timeline: PlaybackTimeline?, trackDuration: TimeInterval = 0) -> Date? {
        guard let t = timeline else { return nil }
        if trackDuration > 0, t.duration > 0, abs(t.duration - trackDuration) > 2 { return nil }
        let rate = t.rate > 0 ? max(t.rate, 0.001) : 0
        let played = rate == 0 ? t.elapsed : t.elapsed / rate
        return t.timestamp.addingTimeInterval(-played)
    }

    /// enabled && a track exists && it plays in Music (FIX_GUIDE F10) && (playing || paused for
    /// less than `hideDelay`).
    static func isVisible(enabled: Bool, hasTrack: Bool, isMusicSource: Bool, isPlaying: Bool,
                          pausedFor: TimeInterval, hideDelay: TimeInterval) -> Bool {
        enabled && hasTrack && isMusicSource && (isPlaying || pausedFor < hideDelay)
    }

    /// Whether a lookup result replaces the document on screen. A re-lookup after the
    /// duration became known keeps the current document when the new result is the same
    /// song (same `songID`) or empty, to avoid flicker (PLAN 3.3 v2).
    static func shouldReplace(current: LyricsDocument?, with new: LyricsDocument?, isRelookup: Bool) -> Bool {
        guard isRelookup, let current else { return true }
        guard let new else { return false }
        return new.songID != current.songID || (new.songID == nil && new != current)
    }

    /// The playlist comes from AppleScript on Music, so only Music has the tab.
    static func playlistTabAvailable(sourceBundleID: String?) -> Bool {
        sourceBundleID == MusicCacheLyricsProvider.musicBundleID
    }

    /// The tab to show: the playlist only while it exists.
    static func effectiveTab(preferred: LyricPreferences.Tab, playlistAvailable: Bool) -> LyricPreferences.Tab {
        playlistAvailable ? preferred : .lyrics
    }

    /// Lyrics come from Music's own cache, so only Music is supported.
    static func supportsLyrics(sourceBundleID: String) -> Bool {
        sourceBundleID == MusicCacheLyricsProvider.musicBundleID
    }

    /// What the view shows for a finished lookup: the Music hint only while nothing was found.
    static func emptyState(for result: LyricsLookupResult) -> LyricsEmptyState {
        if result.document != nil { return .none }
        return result.noSessionEntries ? .openLyricsInMusicOnce : .noLyrics
    }

    /// A finished lookup with nothing found hides the panel (the Music-hint state stays visible).
    static func hidesPanel(document: LyricsDocument?, emptyState: LyricsEmptyState) -> Bool {
        document == nil && emptyState == .noLyrics
    }

    // MARK: Forced card attachment (PLAN 12.3)

    /// "Always shown with Lyrics Card" counts lyrics as on regardless of the saved switch.
    static func effectiveEnabled(saved: Bool, forcedCard: Bool) -> Bool { forcedCard || saved }

    /// ... and pins the placement under the card.
    static func effectivePlacement(saved: LyricPreferences.Placement, forcedCard: Bool) -> LyricPreferences.Placement {
        forcedCard ? .belowCard : saved
    }

    /// The paused auto-hide follows the card while forced, so a pause never counts then.
    /// While the user scrolls the lyrics it never counts either.
    static func effectivePausedFor(_ pausedFor: TimeInterval, forcedCard: Bool, scrolling: Bool = false) -> TimeInterval {
        (forcedCard || scrolling) ? 0 : pausedFor
    }
}
