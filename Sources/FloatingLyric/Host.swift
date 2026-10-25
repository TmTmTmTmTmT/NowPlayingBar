import AppKit

/// Types the host app (NowPlayingBar) uses to talk to the lyrics add-on.
/// The add-on never imports host types; everything crosses this boundary.

/// The track that is currently playing, as the host knows it.
public struct TrackRef: Equatable {
    public var title: String
    public var artist: String?
    public var album: String?
    /// Seconds; 0 when unknown.
    public var duration: TimeInterval
    public var sourceBundleID: String

    public init(title: String, artist: String?, album: String?,
                duration: TimeInterval, sourceBundleID: String) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.sourceBundleID = sourceBundleID
    }
}

/// A playback position sample from the OS. Interpolate with `position(at:)`
/// instead of asking again.
public struct PlaybackTimeline: Equatable {
    public var elapsed: TimeInterval
    /// Wall-clock time at which `elapsed` was sampled by the OS.
    public var timestamp: Date
    public var rate: Double
    public var duration: TimeInterval
    public var isPlaying: Bool

    public init(elapsed: TimeInterval, timestamp: Date, rate: Double,
                duration: TimeInterval, isPlaying: Bool) {
        self.elapsed = elapsed
        self.timestamp = timestamp
        self.rate = rate
        self.duration = duration
        self.isPlaying = isPlaying
    }

    /// Interpolated position at wall clock `now`, clamped to the track.
    public func position(at now: Date) -> TimeInterval {
        let upper = duration > 0 ? duration : .greatestFiniteMagnitude
        guard isPlaying, rate != 0 else { return min(max(elapsed, 0), upper) }
        let advanced = elapsed + now.timeIntervalSince(timestamp) * rate
        return min(max(advanced, 0), upper)
    }
}

/// The host's resolved glass look, so the lyrics panel always matches the
/// control card. The host computes it; the add-on only applies it.
public struct GlassAppearance: Equatable {
    /// false = regular glass, true = clear glass.
    public var isClear: Bool
    /// Hide the frosted blur behind clear glass.
    public var blurHidden: Bool
    public var blurOpacity: CGFloat
    /// Material of the frosted blur layer (see `ClearFrost`).
    public var blurMaterial: NSVisualEffectView.Material
    /// Resolved (appearance-applied) alpha of the black dim layer between blur and glass.
    public var dimAlpha: CGFloat
    /// Resolved alpha of the black glass tint (`NSGlassEffectView.tintColor`).
    public var glassTintAlpha: CGFloat
    /// Pinned Light/Dark look (clear glass forces dark otherwise); nil = follow system.
    public var pinnedDark: Bool?
    /// Opaque text/controls (the host's `solidElements`).
    public var solidElements: Bool

    public init(isClear: Bool, blurHidden: Bool, blurOpacity: CGFloat,
                blurMaterial: NSVisualEffectView.Material = .menu,
                dimAlpha: CGFloat = 0, glassTintAlpha: CGFloat = 0,
                pinnedDark: Bool?, solidElements: Bool) {
        self.isClear = isClear
        self.blurHidden = blurHidden
        self.blurOpacity = blurOpacity
        self.blurMaterial = blurMaterial
        self.dimAlpha = dimAlpha
        self.glassTintAlpha = glassTintAlpha
        self.pinnedDark = pinnedDark
        self.solidElements = solidElements
    }

    public static let regular = GlassAppearance(
        isClear: false, blurHidden: true, blurOpacity: 0.58, blurMaterial: .menu,
        dimAlpha: 0, glassTintAlpha: 0, pinnedDark: true, solidElements: false)
}

/// Callbacks into the host.
public struct LyricHost {
    /// Seek the now-playing app to `seconds`.
    public var seek: (TimeInterval) -> Void
    /// Screen frame of the menu bar widget (for the below-menu-bar placement).
    public var statusItemFrame: () -> NSRect?

    public init(seek: @escaping (TimeInterval) -> Void,
                statusItemFrame: @escaping () -> NSRect?) {
        self.seek = seek
        self.statusItemFrame = statusItemFrame
    }
}

/// Final Clear-glass frost values (PLAN 12.22, "Thin + dim 2"). Single source of
/// truth shared by the host card and the lyrics panel; applies to Clear + blur on only.
public enum ClearFrost {
    public struct Values: Equatable {
        public let material: NSVisualEffectView.Material
        public let blurAlpha: CGFloat
        public let dimAlpha: CGFloat
        public let tintAlpha: CGFloat
    }

    public static let final = Values(material: .hudWindow, blurAlpha: 0.45, dimAlpha: 0.18, tintAlpha: 0)
}

extension GlassAppearance {
    /// All glass (Regular and Clear) is always dark, whatever the system Light/Dark (PLAN 12.25).
    public static let alwaysDark = true

    /// The look the host applies for its glass options.
    public static func resolved(isClear: Bool, noBlur: Bool) -> GlassAppearance {
        guard isClear else { return .regular }
        let f = ClearFrost.final
        return GlassAppearance(
            isClear: true, blurHidden: noBlur, blurOpacity: f.blurAlpha, blurMaterial: f.material,
            dimAlpha: f.dimAlpha, glassTintAlpha: f.tintAlpha,
            pinnedDark: alwaysDark, solidElements: true)
    }
}
