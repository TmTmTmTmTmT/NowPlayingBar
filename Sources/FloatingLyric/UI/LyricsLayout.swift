import Foundation
import CoreGraphics

/// Pure layout and timing rules for the lyrics list. No views, so it is unit-tested.
/// Coordinates are top-down inside the viewport (y grows downward).
enum LyricsLayout {
    enum Metrics {
        static let inactiveOpacity: CGFloat = 0.32
        static let pastOpacity: CGFloat = 0.22
        static let inactiveScale: CGFloat = 0.97
        static let maxBlurDistance = 4
        static let blurPerStep: CGFloat = 1.0
        /// Gaps at least this long get a "..." row (PLAN 4.1).
        static let interludeMinGap: TimeInterval = 6
    }

    /// One list row: a lyric line or the interlude dots shown before `lines[beforeLine]`.
    struct RowStyle: Equatable {
        var y: CGFloat
        var opacity: CGFloat
        var blurRadius: CGFloat
        var scale: CGFloat
        var isVisible: Bool
    }

    struct Input {
        var heights: [CGFloat]
        /// Row that sits on the anchor slot; clamped into range.
        var activeRow: Int
        var context: LyricPreferences.Context
        var visibleLines: Int
        var spacing: CGFloat
        var viewportHeight: CGFloat
        var topPadding: CGFloat
        var bottomPadding: CGFloat
        var blurInactive: Bool
        var isUserScrolling: Bool
        /// Fixed scroll offset while the user scrolls; nil = follow the active row.
        var offsetOverride: CGFloat? = nil
        /// Rows within this distance outside the viewport stay visible (one line).
        var visibilityMargin: CGFloat
    }

    /// Slot (0-based, from the top) that the active line sits on.
    static func anchorSlot(context: LyricPreferences.Context, visibleLines n: Int) -> Int {
        switch context {
        case .around:       return max(n - 1, 0) / 2
        case .upcomingOnly: return 0
        }
    }

    /// Top of each row in content space. Zero-height rows (hidden interludes) take no spacing.
    static func contentTops(heights: [CGFloat], spacing: CGFloat) -> [CGFloat] {
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for h in heights {
            tops.append(y)
            if h > 0 { y += h + spacing }
        }
        return tops
    }

    /// Scroll offset that puts `activeRow` on its anchor slot.
    static func followOffset(_ i: Input) -> CGFloat {
        guard !i.heights.isEmpty else { return 0 }
        let tops = contentTops(heights: i.heights, spacing: i.spacing)
        let active = min(max(i.activeRow, 0), i.heights.count - 1)
        let slots = CGFloat(max(i.visibleLines, 1))
        let pitch = max(i.viewportHeight - i.topPadding - i.bottomPadding, 0) / slots
        let slot = CGFloat(anchorSlot(context: i.context, visibleLines: i.visibleLines))
        return tops[active] - (i.topPadding + slot * pitch)
    }

    static func styles(_ i: Input) -> [RowStyle] {
        guard !i.heights.isEmpty else { return [] }
        let tops = contentTops(heights: i.heights, spacing: i.spacing)
        let offset = i.offsetOverride ?? followOffset(i)
        let active = min(max(i.activeRow, 0), i.heights.count - 1)
        return i.heights.indices.map { r in
            let y = tops[r] - offset
            let h = i.heights[r]
            let distance = abs(r - active)
            let visible = h > 0 && y + h > -i.visibilityMargin && y < i.viewportHeight + i.visibilityMargin
            let opacity: CGFloat
            if r == active { opacity = 1 }
            else { opacity = r < active ? Metrics.pastOpacity : Metrics.inactiveOpacity }
            let blur: CGFloat = (i.blurInactive && !i.isUserScrolling)
                ? CGFloat(min(distance, Metrics.maxBlurDistance)) * Metrics.blurPerStep : 0
            return RowStyle(y: y, opacity: opacity, blurRadius: blur,
                            scale: r == active ? 1 : Metrics.inactiveScale, isVisible: visible)
        }
    }

    // MARK: Timing

    /// Last line whose `begin` has passed. nil = before the first line (intro).
    static func activeLineIndex(for position: TimeInterval, lines: [LyricLine]) -> Int? {
        var lo = 0, hi = lines.count   // first index with begin > position
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].begin <= position { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    /// When the line's last body word ends (background vocals excluded); `line.end` without words.
    static func sungEnd(of line: LyricLine) -> TimeInterval {
        line.words.map(\.end).max() ?? line.end
    }

    /// Earlier lines (index < active) still being sung at `position`, ascending.
    static func lingeringLines(position: TimeInterval, lines: [LyricLine]) -> [Int] {
        guard let active = activeLineIndex(for: position, lines: lines) else { return [] }
        return (0..<active).filter { position < sungEnd(of: lines[$0]) }
    }

    /// Lines before `active` still being sung at real `position` (lead-aware variant).
    static func lingeringLines(position: TimeInterval, before active: Int?, lines: [LyricLine]) -> [Int] {
        guard let active else { return [] }
        return (0..<min(active, lines.count)).filter { position < sungEnd(of: lines[$0]) }
    }

    /// Focus at real time `t`: the centered line / interlude is chosen at `t + lead`;
    /// lingering and interlude progress use real `t`.
    struct FocusResult: Equatable {
        var activeLine: Int?
        var interludeBefore: Int?
        var progress: Double
        var lingering: [Int]
    }
    static func focus(at t: TimeInterval, lead: TimeInterval, lines: [LyricLine]) -> FocusResult {
        let tl = t + lead
        if let info = interludeInfo(position: tl, lines: lines) {
            let start = info.beforeLine == 0 ? 0 : lines[info.beforeLine - 1].end
            let span = lines[info.beforeLine].begin - start
            let p = span > 0 ? min(max((t - start) / span, 0), 1) : 0
            return FocusResult(activeLine: nil, interludeBefore: info.beforeLine, progress: p,
                               lingering: lingeringLines(position: t, before: info.beforeLine, lines: lines))
        }
        let idx = activeLineIndex(for: tl, lines: lines)
        return FocusResult(activeLine: idx, interludeBefore: nil, progress: 0,
                           lingering: lingeringLines(position: t, before: idx, lines: lines))
    }

    /// Index of the line the interlude precedes, and how far through the gap we are.
    struct Interlude: Equatable {
        var beforeLine: Int
        var progress: CGFloat
    }

    /// Lines that are preceded by a gap of at least `interludeMinGap` (the first line counts from 0 s).
    static func interludeLines(lines: [LyricLine]) -> Set<Int> {
        var result = Set<Int>()
        for i in lines.indices {
            let start = i == 0 ? 0 : lines[i - 1].end
            if lines[i].begin - start >= Metrics.interludeMinGap { result.insert(i) }
        }
        return result
    }

    /// Progress 0...1 when `position` is inside such a gap, else nil.
    static func interludeInfo(position: TimeInterval, lines: [LyricLine]) -> Interlude? {
        guard !lines.isEmpty else { return nil }
        let next = (activeLineIndex(for: position, lines: lines).map { $0 + 1 }) ?? 0
        guard next < lines.count else { return nil }
        let start = next == 0 ? 0 : lines[next - 1].end
        let end = lines[next].begin
        guard end - start >= Metrics.interludeMinGap, position >= start, position < end else { return nil }
        return Interlude(beforeLine: next, progress: CGFloat((position - start) / (end - start)))
    }

    /// Fill progress of a word at time `t`; instant words flip at `begin`.
    static func wordProgress(t: TimeInterval, word: LyricWord) -> CGFloat {
        guard word.end > word.begin else { return t >= word.begin ? 1 : 0 }
        return CGFloat(min(max((t - word.begin) / (word.end - word.begin), 0), 1))
    }
}
