import Foundation

/// Interpolates the playback position between OS samples so lyrics can be
/// drawn every frame without asking the OS again.
final class LyricClock {
    enum Metrics {
        /// Constant correction between the OS position and the TTML times (PLAN P7).
        static let timingOffset: TimeInterval = 0
        /// A new sample this far from our own prediction counts as a seek.
        static let jumpThreshold: TimeInterval = 1
        /// A computed position this far behind what is displayed is a seek, not drift (FIX_GUIDE F3).
        static let seekBackThreshold: TimeInterval = 1
    }

    private(set) var timeline: PlaybackTimeline?
    var timingOffset: TimeInterval = Metrics.timingOffset
    /// Highest position handed out within the current track / document; nil after a reset.
    private var displayed: TimeInterval?

    /// True while the position actually moves.
    var isRunning: Bool {
        guard let timeline else { return false }
        return timeline.isPlaying && timeline.rate != 0
    }

    /// Stores a new sample. Returns true when it disagrees with what the previous
    /// sample predicted (seek, track change, or the first sample), so the caller
    /// repositions without animation.
    @discardableResult
    func update(timeline new: PlaybackTimeline, now: Date) -> Bool {
        defer { timeline = new }
        guard let old = timeline else { displayed = nil; return true }
        let jumped = abs(new.position(at: now) - old.position(at: now)) > Metrics.jumpThreshold
        if jumped { displayed = nil }
        return jumped
    }

    func clear() { timeline = nil; displayed = nil }

    /// Forgets the displayed high-water mark: call when the track or document changes.
    func resetDisplayedPosition() { displayed = nil }

    /// Lyric time at wall clock `now`, never negative. Within a track it never moves
    /// backwards by 1 s or less: a pause sample slightly behind the extrapolated position
    /// (the host rounds timestamps) must not make the fill shrink. A bigger step back is a
    /// seek and applies at once. Stateful: call from one place per frame.
    func position(at now: Date) -> TimeInterval {
        guard let timeline else { return 0 }
        let raw = max(timeline.position(at: now) + timingOffset, 0)
        if let shown = displayed, raw < shown, shown - raw <= Metrics.seekBackThreshold {
            return shown
        }
        displayed = raw
        return raw
    }
}
