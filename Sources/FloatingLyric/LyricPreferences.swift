import Foundation

/// Lyrics add-on options. Backed by `UserDefaults`, keys prefixed `lyric.`.
/// Glass look is deliberately absent: the host owns it.
public final class LyricPreferences {
    public static let shared = LyricPreferences()

    private let defaults: UserDefaults

    private enum Key {
        static let enabled          = "lyric.enabled"
        static let placement        = "lyric.placement"
        static let context          = "lyric.context"
        static let lines            = "lyric.lines"
        // Per-placement keys of older versions: read once for migration, never written or deleted.
        static let legacyLinesFloating = "lyric.lines.floating"
        static let legacyLinesCard     = "lyric.lines.card"
        static let legacyLinesMenuBar  = "lyric.lines.menubar"
        static let textSize         = "lyric.textSize"
        static let floatingWidth    = "lyric.floating.width"
        static let floatingLocked   = "lyric.floating.locked"
        static let clickThrough     = "lyric.floating.clickThrough"
        static let pausedHideDelay  = "lyric.pausedHideDelay"
        static let blurInactive     = "lyric.blurInactive"
        static let clickToSeek      = "lyric.clickToSeek"
        static let showTranslation  = "lyric.showTranslation"
        static let lastTab          = "lyric.lastTab"
        static func origin(_ screenID: String) -> String { "lyric.floating.origin.\(screenID)" }
    }

    public enum Placement: Int, CaseIterable {
        case floating = 0, belowCard, belowMenuBar
    }

    /// Which lines are shown around the current one.
    public enum Context: Int, CaseIterable {
        /// Past and upcoming lines.
        case around = 0
        /// Current and upcoming lines only.
        case upcomingOnly
    }

    public enum TextSize: Int, CaseIterable {
        case small = 0, medium, large

        public var scale: CGFloat {
            switch self {
            case .small:  return 0.85
            case .medium: return 1.0
            case .large:  return 1.2
            }
        }
    }

    public enum Tab: Int {
        case lyrics = 0, playlist
    }

    public static let lineChoices = [1, 2, 3, 5, 7, 9]
    public static let lineRange = 1...9
    /// "Hide when paused" choices in seconds.
    public static let pausedHideDelayChoices: [TimeInterval] = [5, 10, 15, 20, 30, 60]
    public static let defaultPausedHideDelay: TimeInterval = 30
    public static let floatingWidthChoices: [CGFloat] = [320, 420, 560]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.enabled:         false,
            Key.placement:       Placement.belowCard.rawValue,
            Key.context:         Context.around.rawValue,
            Key.textSize:        TextSize.medium.rawValue,
            Key.floatingWidth:   420.0,
            Key.floatingLocked:  false,
            Key.clickThrough:    false,
            Key.blurInactive:    true,
            Key.clickToSeek:     false,
            Key.showTranslation: false,
            Key.lastTab:         Tab.lyrics.rawValue,
        ])
        migrateLines()
    }

    public var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    public var placement: Placement {
        get { Placement(rawValue: defaults.integer(forKey: Key.placement)) ?? .belowCard }
        set { defaults.set(newValue.rawValue, forKey: Key.placement) }
    }

    public var context: Context {
        get { Context(rawValue: defaults.integer(forKey: Key.context)) ?? .around }
        set { defaults.set(newValue.rawValue, forKey: Key.context) }
    }

    /// Visible line count for every placement, clamped to `lineRange`.
    public var lines: Int {
        get { Self.clampLines((defaults.object(forKey: Key.lines) as? Int) ?? Self.defaultLines) }
        set { defaults.set(Self.clampLines(newValue), forKey: Key.lines) }
    }

    private static let defaultLines = 3

    private static func clampLines(_ v: Int) -> Int {
        min(max(v, lineRange.lowerBound), lineRange.upperBound)
    }

    /// One-time: the single key takes the old key of the saved placement, so the height the
    /// user was looking at stays. Old keys stay untouched in case of a downgrade.
    private func migrateLines() {
        guard defaults.object(forKey: Key.lines) == nil else { return }
        let legacy: String
        switch placement {
        case .floating:     legacy = Key.legacyLinesFloating
        case .belowCard:    legacy = Key.legacyLinesCard
        case .belowMenuBar: legacy = Key.legacyLinesMenuBar
        }
        let old = defaults.object(forKey: legacy) as? Int
        defaults.set(Self.clampLines(old ?? Self.defaultLines), forKey: Key.lines)
    }

    public var textSize: TextSize {
        get { TextSize(rawValue: defaults.integer(forKey: Key.textSize)) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: Key.textSize) }
    }

    /// Floating panel width, snapped to the nearest preset.
    public var floatingWidth: CGFloat {
        get {
            let v = CGFloat(defaults.double(forKey: Key.floatingWidth))
            return Self.floatingWidthChoices.min { abs($0 - v) < abs($1 - v) } ?? 420
        }
        set { defaults.set(Double(newValue), forKey: Key.floatingWidth) }
    }

    public var floatingLocked: Bool {
        get { defaults.bool(forKey: Key.floatingLocked) }
        set { defaults.set(newValue, forKey: Key.floatingLocked) }
    }

    public var clickThrough: Bool {
        get { defaults.bool(forKey: Key.clickThrough) }
        set { defaults.set(newValue, forKey: Key.clickThrough) }
    }

    /// Seconds of pause before the lyrics panel hides, snapped to the nearest choice.
    public var pausedHideDelay: TimeInterval {
        get {
            guard let v = defaults.object(forKey: Key.pausedHideDelay) as? Double else { return Self.defaultPausedHideDelay }
            return Self.snapPausedHideDelay(v)
        }
        set { defaults.set(Self.snapPausedHideDelay(newValue), forKey: Key.pausedHideDelay) }
    }

    static func snapPausedHideDelay(_ v: TimeInterval) -> TimeInterval {
        Self.pausedHideDelayChoices.min { abs($0 - v) < abs($1 - v) } ?? defaultPausedHideDelay
    }

    public var blurInactive: Bool {
        get { defaults.bool(forKey: Key.blurInactive) }
        set { defaults.set(newValue, forKey: Key.blurInactive) }
    }

    /// Clicking a lyric line seeks to it. Off by default: it fights window dragging.
    public var clickToSeek: Bool {
        get { defaults.bool(forKey: Key.clickToSeek) }
        set { defaults.set(newValue, forKey: Key.clickToSeek) }
    }

    public var showTranslation: Bool {
        get { defaults.bool(forKey: Key.showTranslation) }
        set { defaults.set(newValue, forKey: Key.showTranslation) }
    }

    public var lastTab: Tab {
        get { Tab(rawValue: defaults.integer(forKey: Key.lastTab)) ?? .lyrics }
        set { defaults.set(newValue.rawValue, forKey: Key.lastTab) }
    }

    /// Saved top-left of the floating panel on a screen, if any.
    public func floatingOrigin(screenID: String) -> CGPoint? {
        guard let a = defaults.array(forKey: Key.origin(screenID)) as? [Double], a.count == 2 else { return nil }
        return CGPoint(x: a[0], y: a[1])
    }

    public func setFloatingOrigin(_ p: CGPoint, screenID: String) {
        defaults.set([Double(p.x), Double(p.y)], forKey: Key.origin(screenID))
    }
}
