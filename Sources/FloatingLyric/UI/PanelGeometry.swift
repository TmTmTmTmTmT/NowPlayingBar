import AppKit

/// A screen reduced to the numbers placement needs, so frame math is testable
/// without real displays. `id` is the `NSScreenNumber` string used for saved origins.
struct ScreenInfo: Equatable {
    var id: String
    var frame: NSRect
    var visibleFrame: NSRect
}

/// Pure frame math for the three placements (PLAN 11.2). All frames are in
/// screen coordinates (origin bottom-left); "top-left" means (minX, maxY).
enum PanelGeometry {
    enum Metrics {
        static let belowCardGap: CGFloat = 8
        static let belowMenuBarGap: CGFloat = 15       // same as the card under the widget
        static let screenInset: CGFloat = 8
        static let floatingTopOffset: CGFloat = 60     // below the menu bar on the main screen
        static let menuBarWidth: CGFloat = 320
        static let minPlaylistHeight: CGFloat = 260
        /// A saved origin counts as on-screen when this much of the panel is visible.
        static let minVisible = CGSize(width: 40, height: 24)
        /// A status item's bottom edge may sit this far below the visible area's top (rounding).
        static let menuBarStripSlack: CGFloat = 2
    }

    static func cornerRadius(_ p: LyricPreferences.Placement) -> CGFloat {
        switch p {
        case .floating:     return 26
        case .belowCard:    return 22
        case .belowMenuBar: return 18
        }
    }

    /// Equal to the corner radius minus the 2pt glass edge (PLAN 11.2 table).
    static func horizontalPadding(_ p: LyricPreferences.Placement) -> CGFloat {
        switch p {
        case .floating:     return 24
        case .belowCard:    return 22
        case .belowMenuBar: return 16
        }
    }

    /// The playlist tab never shrinks below `minPlaylistHeight`; the menu bar strip has no tabs.
    static func height(placement: LyricPreferences.Placement, lyricsHeight: CGFloat,
                       tab: LyricPreferences.Tab) -> CGFloat {
        if tab == .playlist && placement != .belowMenuBar {
            return max(lyricsHeight, Metrics.minPlaylistHeight)
        }
        return lyricsHeight
    }

    static func width(placement: LyricPreferences.Placement, floatingWidth: CGFloat,
                      cardWidth: CGFloat?) -> CGFloat {
        switch placement {
        case .floating:     return floatingWidth
        case .belowCard:    return cardWidth ?? floatingWidth
        case .belowMenuBar: return Metrics.menuBarWidth
        }
    }

    // MARK: Floating

    /// Centered on the main screen, `floatingTopOffset` under the top of its visible area.
    static func defaultFloatingFrame(size: CGSize, on screen: ScreenInfo) -> NSRect {
        let v = screen.visibleFrame
        let top = v.maxY - Metrics.floatingTopOffset
        return NSRect(x: v.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }

    static func isOnScreen(_ frame: NSRect, screens: [ScreenInfo]) -> Bool {
        screens.contains {
            let i = frame.intersection($0.visibleFrame)
            return !i.isNull && i.width >= Metrics.minVisible.width && i.height >= Metrics.minVisible.height
        }
    }

    /// A status item window that has not been laid out yet reports a frame near the origin (or
    /// none at all). Plausible = non-empty, inside a screen, bottom edge within the menu bar strip.
    static func isPlausibleStatusItemFrame(_ frame: NSRect, screens: [ScreenInfo]) -> Bool {
        guard frame.width >= 1, frame.height > 0 else { return false }
        return screens.contains {
            $0.frame.contains(frame) && frame.minY >= $0.visibleFrame.maxY - Metrics.menuBarStripSlack
        }
    }

    /// Saved top-left of the first screen (main first) that has one and still shows it;
    /// otherwise the default spot on `screens[0]`. `saved` maps a screen id to its stored top-left.
    static func floatingFrame(size: CGSize, screens: [ScreenInfo],
                              saved: (String) -> CGPoint?) -> NSRect {
        for screen in screens {
            guard let tl = saved(screen.id) else { continue }
            let frame = NSRect(x: tl.x, y: tl.y - size.height, width: size.width, height: size.height)
            if isOnScreen(frame, screens: screens) { return frame }
        }
        guard let main = screens.first else {
            return NSRect(origin: .zero, size: size)
        }
        return defaultFloatingFrame(size: size, on: main)
    }

    // MARK: Attached

    /// Directly under the card: same x, `belowCardGap` below its bottom edge.
    static func belowCardFrame(card: NSRect, height: CGFloat) -> NSRect {
        NSRect(x: card.minX, y: card.minY - Metrics.belowCardGap - height, width: card.width, height: height)
    }

    /// Centered under the status item, `belowMenuBarGap` below it, kept `screenInset` inside the screen.
    static func belowMenuBarFrame(statusItem: NSRect, screen: NSRect, size: CGSize) -> NSRect {
        var x = statusItem.midX - size.width / 2
        x = min(max(x, screen.minX + Metrics.screenInset), screen.maxX - size.width - Metrics.screenInset)
        return NSRect(x: x, y: statusItem.minY - size.height - Metrics.belowMenuBarGap,
                      width: size.width, height: size.height)
    }

    /// The menu bar strip while the card is open: dropped under the card (card width,
    /// `belowCardGap`) instead of hanging under the status item (PLAN 12.1). With no card it is
    /// the normal strip frame, so open and close always derive from the current state.
    static func menuBarStripFrame(dockedCard: NSRect?, statusItem: NSRect, screen: NSRect, size: CGSize) -> NSRect {
        if let card = dockedCard { return belowCardFrame(card: card, height: size.height) }
        return belowMenuBarFrame(statusItem: statusItem, screen: screen, size: size)
    }

    // MARK: Sliding

    /// Slide timing: same curve as the host card's `smoothCurve` (0.33, 0, 0.2, 1), 0.30 s.
    static let slideDuration: TimeInterval = 0.30
    static let slideControlPoints = (x1: 0.33, y1: 0.0, x2: 0.2, y2: 1.0)

    /// Eased progress for linear time `t` (0...1) on a CSS-style cubic Bezier.
    static func eased(_ t: Double, controlPoints c: (x1: Double, y1: Double, x2: Double, y2: Double) = slideControlPoints) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        func coord(_ u: Double, _ a: Double, _ b: Double) -> Double {
            let v = 1 - u
            return 3 * v * v * u * a + 3 * v * u * u * b + u * u * u
        }
        var lo = 0.0, hi = 1.0, u = t
        for _ in 0..<40 {                       // solve x(u) = t by bisection (x is monotonic)
            u = (lo + hi) / 2
            if coord(u, c.x1, c.x2) < t { lo = u } else { hi = u }
        }
        return coord(u, c.y1, c.y2)
    }

    /// Frame between `from` and `to`; `progress` 0...1 applies to origin and size alike.
    static func interpolate(from: NSRect, to: NSRect, progress p: Double) -> NSRect {
        let k = CGFloat(p)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }
        return NSRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
                      width: mix(from.width, to.width), height: mix(from.height, to.height))
    }

    // MARK: Resizing

    /// New height with the top edge fixed, so the panel grows downward.
    static func resized(_ frame: NSRect, height: CGFloat) -> NSRect {
        NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    /// Pushes `frame` fully inside `visible`: up when the bottom overflows, down when the top
    /// does, same horizontally. A frame taller than `visible` keeps its top edge visible.
    static func clamped(_ frame: NSRect, into visible: NSRect) -> NSRect {
        var f = frame
        f.origin.x = max(min(f.minX, visible.maxX - f.width), visible.minX)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }

    /// `frame` pushed into the visible area of the screen it overlaps most (the first screen
    /// when none overlaps). Unchanged without screens.
    static func clamped(_ frame: NSRect, screens: [ScreenInfo]) -> NSRect {
        func overlap(_ s: ScreenInfo) -> CGFloat {
            let i = frame.intersection(s.frame)
            return i.isNull ? 0 : i.width * i.height
        }
        guard let first = screens.first else { return frame }
        let best = screens.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil } ?? first
        return clamped(frame, into: best.visibleFrame)
    }

    /// Frame hanging from a top-left `anchor` with `size`, growing downward.
    static func frame(anchor: CGPoint, size: CGSize) -> NSRect {
        NSRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height)
    }

    /// Top-left to store for a dragged floating frame.
    static func topLeft(of frame: NSRect) -> CGPoint { CGPoint(x: frame.minX, y: frame.maxY) }
}

extension ScreenInfo {
    /// The menu bar screen first (`NSScreen.screens[0]`), then the others.
    static func current() -> [ScreenInfo] {
        NSScreen.screens.map { ScreenInfo(id: $0.lyricScreenID, frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }
}

extension NSScreen {
    /// Stable per-display key for saved origins.
    var lyricScreenID: String {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "unknown"
    }
}
