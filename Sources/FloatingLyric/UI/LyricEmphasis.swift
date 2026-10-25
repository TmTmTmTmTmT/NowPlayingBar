import Foundation
import CoreGraphics

/// Pure rules for the word-group emphasis (PLAN 4.1 v5-v9): grouping, glyph curve, fill-edge
/// width and glow. No layers, so it is unit-tested.
enum LyricEmphasis {
    enum Metrics {
        /// A group is emphasized when its longest span is held at least this long.
        static let minDuration: TimeInterval = 1
        /// A group whose longest span lasts at least this long is "held": its glyphs move as one (PLAN 12.29).
        static let heldSpanMin: TimeInterval = 0.8
        /// Held group (v2, PLAN 12.32): the whole word rises to its peak within this time of the group start.
        static let riseDuration: TimeInterval = 0.6
        static let restLift: CGFloat = 1.5
        /// Peak lift = rest + peakLiftGain * (0.5 + 0.5 s); scale = 1 + peakScaleGain * (0.5 + 0.5 s).
        static let peakLiftGain: CGFloat = 0.75
        static let peakScaleGain: CGFloat = 0.04
        static let settleDuration: TimeInterval = 0.9
        /// Neighbor weights by glyph distance inside one group (v9); farther glyphs get 0.
        static let neighborWeights: [CGFloat] = [1, 0.35, 0.12]
        /// Strength s = clamp((H - strengthBase) / strengthSpan, 0, 1).
        static let strengthBase: TimeInterval = 1
        static let strengthSpan: TimeInterval = 3
        static let glowFallEnd: TimeInterval = 0.7
        static let glowBase: Float = 0.6
        static let glowStrengthGain: Float = 0.4
        static let edgeEmShort: CGFloat = 0.5
        static let edgeEmLong: CGFloat = 1.2
        /// Glow amplitude while Reduce Motion is on (times 0.6 + 0.4 s); glow and brightness drop over `reducedFade` after the group ended.
        static let reducedGlow: Float = 0.25
        static let reducedFade: TimeInterval = 0.3
        /// Glow radius as a share of the font size (v6: path shadow, 17 pt -> 8.5 pt).
        static let glowRadiusEm: CGFloat = 0.5
        static let maxGlowDark: Float = 0.8
        static let maxGlowLight: Float = 0.3
    }

    /// Consecutive main-vocal spans joined without whitespace.
    struct Group: Equatable {
        var range: Range<Int>          // indices into the words
        var begin: TimeInterval
        var end: TimeInterval
        var strength: CGFloat
        /// Longest span duration of the group; defaults to `end - begin` for hand-built groups.
        var longestSpan: TimeInterval? = nil
        var isHeld: Bool { LyricEmphasis.isHeld(longestSpan: longestSpan ?? (end - begin)) }
    }

    /// Held group predicate (PLAN 12.29): longest span >= `heldSpanMin`.
    static func isHeld(longestSpan: TimeInterval) -> Bool {
        longestSpan.isFinite && longestSpan >= Metrics.heldSpanMin
    }

    /// Held group rise (PLAN 12.32): a(t) = ease(clamp((t - begin) / max(riseDuration, end - begin))).
    /// The rise spans the whole group (at least `riseDuration`), so wave, glow and HDR level all reach
    /// full exactly at the group end; the whole word rises together, independent of the fill.
    static func heldRise(t: TimeInterval, groupBegin: TimeInterval, groupEnd: TimeInterval) -> CGFloat {
        guard t.isFinite, groupBegin.isFinite, groupEnd.isFinite else { return 0 }
        return CGFloat(ease((t - groupBegin) / max(Metrics.riseDuration, groupEnd - groupBegin)))
    }

    /// Held group: every glyph shares r = a (already eased, see `heldRise`).
    static func heldInfluence(count: Int, rise a: CGFloat) -> [CGFloat] {
        [CGFloat](repeating: clamp01(a), count: max(count, 0))
    }

    static func strength(groupDuration h: TimeInterval) -> CGFloat {
        guard h.isFinite else { return 0 }
        return CGFloat(min(max((h - Metrics.strengthBase) / Metrics.strengthSpan, 0), 1))
    }

    /// Emphasized word groups of the main vocal block (x-bg and translation never reach this).
    /// A span whose `trailingSpace` is false is glued to the next one.
    static func groups(words: [LyricWord]) -> [Group] {
        var out: [Group] = []
        var start = 0
        for i in words.indices where i == words.count - 1 || words[i].trailingSpace {
            let slice = words[start...i]
            let longest = slice.map { $0.end - $0.begin }.max() ?? 0
            let begin = slice.first!.begin, end = slice.map(\.end).max()!
            if longest >= Metrics.minDuration, begin.isFinite, end.isFinite {
                out.append(Group(range: start..<(i + 1), begin: begin, end: end, strength: strength(groupDuration: end - begin), longestSpan: longest))
            }
            start = i + 1
        }
        return out
    }

    /// Fill-edge width in em: 0.5 for short words up to 1.2 for words of 1.5 s and more.
    static func edgeEm(duration: TimeInterval) -> CGFloat {
        let t = CGFloat(min(max((duration - 0.3) / 1.2, 0), 1))
        guard t.isFinite else { return Metrics.edgeEmShort }
        return Metrics.edgeEmShort + (Metrics.edgeEmLong - Metrics.edgeEmShort) * t
    }

    static func peakLift(strength s: CGFloat) -> CGFloat {
        Metrics.restLift + Metrics.peakLiftGain * (0.5 + 0.5 * clamp01(s))
    }
    static func peakScale(strength s: CGFloat) -> CGFloat { 1 + Metrics.peakScaleGain * (0.5 + 0.5 * clamp01(s)) }

    private static func clamp01(_ x: CGFloat) -> CGFloat { x.isFinite ? min(max(x, 0), 1) : 0 }

    /// smootherstep 6u^5 - 15u^4 + 10u^3: 0 -> 1 with zero speed and acceleration at both ends (v7).
    static func ease(_ u: Double) -> Double {
        let x = min(max(u, 0), 1)
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

    /// How much of a glyph the fill has covered, 0...1 (v8). `front` is the span's mask front
    /// (`p * (wordWidth + edge)`, the very value the fill mask uses); `left`/`width` place the glyph
    /// inside the span. 1 exactly when the soft edge has fully passed the glyph.
    static func coverage(front: CGFloat, left: CGFloat, width: CGFloat, edge: CGFloat) -> CGFloat {
        let total = width + edge
        guard front.isFinite, left.isFinite, total.isFinite, total > 0 else { return 0 }
        return clamp01((front - left) / total)
    }

    /// Group fill ratio g = sum(c_i * w_i) / sum(w_i) over the group's glyphs (fallback word pieces
    /// count with their span coverage and piece width).
    static func groupFill<S: Sequence>(_ parts: S) -> CGFloat where S.Element == (coverage: CGFloat, width: CGFloat) {
        var covered: CGFloat = 0, total: CGFloat = 0
        for part in parts where part.width.isFinite && part.width > 0 {
            covered += clamp01(part.coverage) * part.width
            total += part.width
        }
        return total > 0 ? covered / total : 0
    }

    /// Lift progress r_i = max_j(e(c_j) * w(|i - j|)) of the glyphs of ONE group, in group glyph order (v9).
    /// `coverages` are the raw c_j (fallback pieces count as one glyph each); the result is eased, 0...1.
    static func influence(coverages: [CGFloat]) -> [CGFloat] {
        let e = coverages.map { CGFloat(ease(Double(clamp01($0)))) }
        let w = Metrics.neighborWeights
        return e.indices.map { i in
            var r: CGFloat = 0
            for d in 0..<w.count {
                if i - d >= 0 { r = max(r, e[i - d] * w[d]) }
                if d > 0, i + d < e.count { r = max(r, e[i + d] * w[d]) }
            }
            return r
        }
    }

    /// Lift (pt) and scale of one glyph (v9): `peak * r` while the fill passes (`r` = neighbor-weighted
    /// progress from `influence`), held until `groupEnd`; then the whole group settles together over
    /// 0.9 s from its current value to exactly (1.5, 1) with the same curve, no undershoot.
    /// `endInfluence` is r at `groupEnd`, so the settle starts where the rise stopped.
    static func glyphMotion(t: TimeInterval, groupEnd: TimeInterval, influence r: CGFloat, endInfluence: CGFloat,
                            strength: CGFloat) -> (lift: CGFloat, scale: CGFloat) {
        let rest = Metrics.restLift
        guard t.isFinite, groupEnd.isFinite else { return (rest, 1) }
        let peak = peakLift(strength: strength)
        let grow = peakScale(strength: strength) - 1
        guard t >= groupEnd else {
            let k = clamp01(r)
            return (peak * k, 1 + grow * k)
        }
        let k0 = clamp01(endInfluence)
        let lift0 = peak * k0, scale0 = grow * k0
        let u = (t - groupEnd) / Metrics.settleDuration
        guard u < 1 else { return (rest, 1) }
        let k = CGFloat(ease(u))
        return (lift0 + (rest - lift0) * k, 1 + scale0 * (1 - k))
    }

    /// 0...1 HDR brightness share of a glyph: `e(c)` while the fill passes, back to 0 with the settle
    /// (`settle` seconds after the group ended; Reduce Motion passes its short fade).
    static func level(coverage c: CGFloat, endCoverage: CGFloat, sinceEnd e: TimeInterval, settle: TimeInterval) -> CGFloat {
        level(eased: CGFloat(ease(Double(clamp01(c)))), endEased: CGFloat(ease(Double(clamp01(endCoverage)))), sinceEnd: e, settle: settle)
    }

    /// Same as `level(coverage:...)` for inputs that are already eased (held group rise `a`, v2).
    static func level(eased k: CGFloat, endEased: CGFloat, sinceEnd e: TimeInterval, settle: TimeInterval) -> CGFloat {
        guard e.isFinite else { return 0 }
        guard e >= 0 else { return clamp01(k) }
        let u = e / max(settle, 1e-6)
        guard u < 1 else { return 0 }
        return CGFloat(Double(clamp01(endEased)) * (1 - ease(u)))
    }

    /// Group glow (v8): fills with the group (`g` = group fill ratio), scales with strength, fades within 0.7 s after the group ended.
    static func glow(fill g: CGFloat, sinceEnd e: TimeInterval, strength s: CGFloat, maxGlow: Float) -> Float {
        glow(eased: CGFloat(ease(Double(clamp01(g)))), sinceEnd: e, strength: s, maxGlow: maxGlow)
    }

    /// Glow for an already eased input (held group rise `a`, v2).
    static func glow(eased k: CGFloat, sinceEnd e: TimeInterval, strength s: CGFloat, maxGlow: Float) -> Float {
        guard k.isFinite, e.isFinite else { return 0 }
        let fall = 1 - ease(max(e, 0) / Metrics.glowFallEnd)
        let gain = Metrics.glowBase + Metrics.glowStrengthGain * Float(clamp01(s))
        return maxGlow * gain * Float(clamp01(k)) * Float(fall)
    }

    /// Reduce Motion glow: same fill sync at the fixed 0.25 strength, gone within the 0.3 s fade after the group ended.
    static func reducedGlow(fill g: CGFloat, sinceEnd e: TimeInterval, strength s: CGFloat) -> Float {
        reducedGlow(eased: CGFloat(ease(Double(clamp01(g)))), sinceEnd: e, strength: s)
    }

    static func reducedGlow(eased k: CGFloat, sinceEnd e: TimeInterval, strength s: CGFloat) -> Float {
        guard k.isFinite, e.isFinite else { return 0 }
        let fall = 1 - ease(max(e, 0) / Metrics.reducedFade)
        let gain = Metrics.glowBase + Metrics.glowStrengthGain * Float(clamp01(s))
        return Metrics.reducedGlow * gain * Float(clamp01(k)) * Float(fall)
    }

    /// Composed character sequences of `text` (Hangul syllable, combining marks, emoji as one),
    /// without whitespace. Ranges are UTF-16 offsets into `text`.
    static func characterRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        var i = 0
        while i < ns.length {
            let r = ns.rangeOfComposedCharacterSequence(at: i)
            let piece = ns.substring(with: r)
            if !piece.allSatisfy(\.isWhitespace) { out.append(r) }
            i = r.location + max(r.length, 1)
        }
        return out
    }

    /// Whole-pixel spans for pieces that share boundaries: they tile `edges.first...edges.last`
    /// without gap or overlap. The outer edges round outward, inner ones to nearest.
    static func pixelSpans(edges: [CGFloat], scale: CGFloat) -> [Range<Int>] {
        guard edges.count >= 2 else { return [] }
        var bounds: [Int] = edges.enumerated().map { i, x in
            let v = x * scale
            if i == 0 { return Int(floor(v)) }
            if i == edges.count - 1 { return Int(ceil(v)) }
            return Int(v.rounded())
        }
        for i in 1..<bounds.count { bounds[i] = max(bounds[i], bounds[i - 1]) }
        return (0..<(bounds.count - 1)).map { bounds[$0]..<bounds[$0 + 1] }
    }
}
