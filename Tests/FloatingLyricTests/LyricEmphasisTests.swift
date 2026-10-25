import Foundation
import CoreGraphics
import Testing
@testable import FloatingLyric

@Suite struct LyricEmphasisTests {
    @Test func edgeWidthInterpolates() {
        #expect(LyricEmphasis.edgeEm(duration: 0.1) == 0.5)
        #expect(LyricEmphasis.edgeEm(duration: 0.3) == 0.5)
        #expect(abs(LyricEmphasis.edgeEm(duration: 0.9) - 0.85) < 1e-9)
        #expect(abs(LyricEmphasis.edgeEm(duration: 1.5) - 1.2) < 1e-9)
        #expect(LyricEmphasis.edgeEm(duration: 9) == 1.2)
        #expect(LyricEmphasis.edgeEm(duration: .nan) == 0.5)
    }

    private func word(_ text: String, _ b: TimeInterval, _ e: TimeInterval, space: Bool = false) -> LyricWord {
        LyricWord(text: text, begin: b, end: e, trailingSpace: space)
    }

    @Test func groupsJoinSpansWithoutWhitespace() {
        let w = [word("가", 0, 0.4), word("나다", 0.4, 2.4), word("라", 2.4, 3, space: true),
                 word("마", 3, 3.3, space: true), word("바", 3.3, 5.5)]
        let g = LyricEmphasis.groups(words: w)
        #expect(g.count == 2)
        #expect(g[0].range == 0..<3 && g[0].begin == 0 && g[0].end == 3)
        #expect(abs(g[0].strength - 2.0 / 3) < 1e-9)
        #expect(g[1].range == 4..<5 && abs(g[1].strength - 0.4) < 1e-9)
    }

    @Test func groupsNeedOneLongSpanAndShortOnesAreSkipped() {
        let short = [word("가", 0, 0.5), word("나", 0.5, 1.4), word("다", 1.4, 2)]
        #expect(LyricEmphasis.groups(words: short).isEmpty)                 // H = 2 but no span >= 1 s
        let split = [word("가", 0, 1, space: true), word("나", 1, 1.5)]
        let g = LyricEmphasis.groups(words: split)
        #expect(g.count == 1 && g[0].range == 0..<1 && g[0].strength == 0)  // H = 1 -> s = 0
        #expect(LyricEmphasis.groups(words: []).isEmpty)
        let long = [word("가", 0, 4)]
        #expect(LyricEmphasis.groups(words: long)[0].strength == 1)
    }

    @Test func strengthClamps() {
        #expect(LyricEmphasis.strength(groupDuration: 0.2) == 0)
        #expect(LyricEmphasis.strength(groupDuration: 1) == 0)
        #expect(abs(LyricEmphasis.strength(groupDuration: 2.5) - 0.5) < 1e-9)
        #expect(LyricEmphasis.strength(groupDuration: 4) == 1)
        #expect(LyricEmphasis.strength(groupDuration: 40) == 1)
        #expect(LyricEmphasis.strength(groupDuration: .nan) == 0)
    }

    @Test func peaksScaleWithStrength() {
        #expect(LyricEmphasis.peakLift(strength: 0) == 1.875 && LyricEmphasis.peakLift(strength: 1) == 2.25)
        #expect(abs(LyricEmphasis.peakScale(strength: 0) - 1.02) < 1e-12 && abs(LyricEmphasis.peakScale(strength: 1) - 1.04) < 1e-12)
    }

    @Test func easeIsSmootherstepWithZeroFirstAndSecondDerivativeAtEnds() {
        #expect(LyricEmphasis.ease(0) == 0 && LyricEmphasis.ease(1) == 1 && abs(LyricEmphasis.ease(0.5) - 0.5) < 1e-12)
        let h = 1e-4
        let e = LyricEmphasis.ease
        #expect(abs((e(h) - e(0)) / h) < 1e-3)                       // e'(0) ~ 0
        #expect(abs((e(1) - e(1 - h)) / h) < 1e-3)                   // e'(1) ~ 0
        // e''(u) = 120u^3 - 180u^2 + 60u ~ 60u near the ends, so the second difference is ~1e-2 (0 in the limit).
        #expect(abs((e(2 * h) - 2 * e(h) + e(0)) / (h * h)) < 0.1)
        #expect(abs((e(1) - 2 * e(1 - h) + e(1 - 2 * h)) / (h * h)) < 0.1)
        #expect(LyricEmphasis.ease(-1) == 0 && LyricEmphasis.ease(2) == 1)
    }

    // Glyph of width 40 at offset 100 in a 200 pt span with a 20 pt edge; the span is sung from t = 10 to 12.
    /// Lift progress of a lone glyph with coverage c (no neighbors).
    private func R(_ c: CGFloat) -> CGFloat { CGFloat(LyricEmphasis.ease(Double(c.isFinite ? min(max(c, 0), 1) : 0))) }

    private let span = (width: CGFloat(200), edge: CGFloat(20), left: CGFloat(100), gw: CGFloat(40), begin: 10.0, dur: 2.0)

    private func coverage(at t: Double) -> CGFloat {
        let p = CGFloat(min(max((t - span.begin) / span.dur, 0), 1))
        return LyricEmphasis.coverage(front: p * (span.width + span.edge), left: span.left, width: span.gw, edge: span.edge)
    }

    @Test func coverageIsZeroBeforeAndOneAfterTheEdgePassed() {
        #expect(LyricEmphasis.coverage(front: 0, left: 100, width: 40, edge: 20) == 0)
        #expect(LyricEmphasis.coverage(front: 100, left: 100, width: 40, edge: 20) == 0)      // front at the left edge
        #expect(abs(LyricEmphasis.coverage(front: 130, left: 100, width: 40, edge: 20) - 0.5) < 1e-12)
        #expect(LyricEmphasis.coverage(front: 160, left: 100, width: 40, edge: 20) == 1)      // edge fully past the glyph
        #expect(LyricEmphasis.coverage(front: 999, left: 100, width: 40, edge: 20) == 1)
        #expect(LyricEmphasis.coverage(front: .nan, left: 0, width: 40, edge: 20) == 0)
        #expect(LyricEmphasis.coverage(front: 5, left: 0, width: 0, edge: 0) == 0)
    }

    @Test func groupFillWeighsPiecesByWidth() {
        let wrapped: [(coverage: CGFloat, width: CGFloat)] = [(1, 30), (0.5, 10), (0, 60)]   // pieces over two text lines
        #expect(abs(LyricEmphasis.groupFill(wrapped) - 0.35) < 1e-12)
        #expect(LyricEmphasis.groupFill([(coverage: CGFloat, width: CGFloat)]()) == 0)
        #expect(LyricEmphasis.groupFill([(coverage: CGFloat(2), width: CGFloat(10))]) == 1)     // coverage clamps
        #expect(LyricEmphasis.groupFill([(coverage: CGFloat(1), width: CGFloat(0))]) == 0)
    }

    @Test func motionIsZeroAtCoverageZeroAndPeakAtCoverageOne() {
        for s in [CGFloat(0), 0.5, 1] {
            let pl = LyricEmphasis.peakLift(strength: s), ps = LyricEmphasis.peakScale(strength: s)
            let zero = LyricEmphasis.glyphMotion(t: 5, groupEnd: 9, influence: R(0), endInfluence: R(1), strength: s)
            #expect(zero.lift == 0 && zero.scale == 1)
            let one = LyricEmphasis.glyphMotion(t: 8.99, groupEnd: 9, influence: R(1), endInfluence: R(1), strength: s)
            #expect(abs(one.lift - pl) < 1e-12 && abs(one.scale - ps) < 1e-12)
            let half = LyricEmphasis.glyphMotion(t: 8, groupEnd: 9, influence: R(0.5), endInfluence: R(1), strength: s)
            #expect(abs(half.lift - pl / 2) < 1e-12)                          // e(0.5) = 0.5
        }
        #expect(LyricEmphasis.peakLift(strength: 0) == 1.875 && LyricEmphasis.peakLift(strength: 1) == 2.25)
        #expect(abs(LyricEmphasis.peakScale(strength: 0) - 1.02) < 1e-12 && abs(LyricEmphasis.peakScale(strength: 1) - 1.04) < 1e-12)
    }

    @Test func liftHdrLevelAndGlowRiseTogetherWithTheFront() {
        let hold = 20.0
        var prev: (lift: CGFloat, scale: CGFloat, level: CGFloat, glow: Float) = (-1, 0, -1, -1)
        var t = 9.9
        var moved = 0
        while t <= 12.1 {
            let c = coverage(at: t)
            let m = LyricEmphasis.glyphMotion(t: t, groupEnd: hold, influence: R(c), endInfluence: R(1), strength: 1)
            let k = LyricEmphasis.level(coverage: c, endCoverage: 1, sinceEnd: t - hold, settle: 0.9)
            let hdr = LyricHDR.level(progress: k, strength: 1, headroom: 16)
            let glow = LyricEmphasis.glow(fill: c, sinceEnd: t - hold, strength: 1, maxGlow: 0.8)
            #expect(m.lift >= prev.lift && m.scale >= prev.scale && hdr >= prev.level && glow >= prev.glow)
            // All three move on exactly the same steps: a plateau in one is a plateau in the others.
            if c > 0.02 && c < 0.98 { #expect(m.lift > prev.lift - 1e-12 && hdr >= prev.level); moved += 1 }
            prev = (m.lift, m.scale, hdr, glow)
            t += 0.001
        }
        #expect(moved > 100)
        #expect(prev.lift == 2.25 && prev.level == 1.6 && abs(prev.glow - 0.8) < 1e-6)
        let first = LyricEmphasis.glyphMotion(t: 9, groupEnd: hold, influence: R(coverage(at: 9)), endInfluence: R(1), strength: 1)
        #expect(first.lift == 0 && LyricEmphasis.glow(fill: 0, sinceEnd: -11, strength: 1, maxGlow: 0.8) == 0)
        #expect(LyricHDR.level(progress: LyricEmphasis.level(coverage: 0, endCoverage: 1, sinceEnd: -1, settle: 0.9), strength: 1, headroom: 16) == 1.03)
    }

    @Test func liftHasNoStepForOneMillisecondFrontSteps() {
        // dc/dt of the front sweep; smootherstep slope is at most 1.875.
        let dcdt = Double(span.width + span.edge) / span.dur / Double(span.gw + span.edge)
        for s in [CGFloat(0), 1] {
            let pl = LyricEmphasis.peakLift(strength: s)
            var prev: CGFloat = 0
            var t = 9.9
            while t <= 12.1 {
                let l = LyricEmphasis.glyphMotion(t: t, groupEnd: 99, influence: R(coverage(at: t)), endInfluence: R(1), strength: s).lift
                #expect(abs(l - prev) <= pl * 1.875 * CGFloat(dcdt) * 0.001 * 1.1 + 1e-12)
                prev = l
                t += 0.001
            }
        }
    }

    @Test func settleIsContinuousAtGroupEndMonotoneAndExact() {
        // Fill finished (endCoverage 1) and fill frozen partway (e.g. the span ends before it covers the glyph).
        for (c, s) in [(CGFloat(1), CGFloat(0)), (1, 1), (0.4, 1), (0, 1)] {
            let pl = LyricEmphasis.peakLift(strength: s)
            let end = 9.0
            let before = LyricEmphasis.glyphMotion(t: end - 0.001, groupEnd: end, influence: R(c), endInfluence: R(c), strength: s)
            let at = LyricEmphasis.glyphMotion(t: end, groupEnd: end, influence: R(c), endInfluence: R(c), strength: s)
            #expect(abs(at.lift - before.lift) < 1e-4 && abs(at.scale - before.scale) < 1e-4)      // no jump
            var prev = at
            var t = end
            while t <= end + 1.0 {
                t += 0.001
                let m = LyricEmphasis.glyphMotion(t: t, groupEnd: end, influence: R(c), endInfluence: R(c), strength: s)
                #expect(m.lift.isFinite && m.scale.isFinite && m.lift <= pl + 1e-9)
                if at.lift >= 1.5 { #expect(m.lift >= 1.5 - 1e-9 && m.lift <= prev.lift + 1e-9 && m.scale >= 1 - 1e-12) }
                else { #expect(m.lift >= prev.lift - 1e-9 && m.lift <= 1.5 + 1e-9) }
                #expect(abs(m.lift - prev.lift) <= (abs(at.lift - 1.5)) * 1.875 / 0.9 * 0.001 * 1.1 + 1e-12)
                prev = m
            }
            #expect(prev.lift == 1.5 && prev.scale == 1)
            let mid = LyricEmphasis.glyphMotion(t: end + 0.45, groupEnd: end, influence: R(c), endInfluence: R(c), strength: s)
            #expect(abs(mid.lift - (at.lift + 1.5) / 2) < 1e-9)                    // e(0.5) = 0.5
            #expect(LyricEmphasis.glyphMotion(t: end + 0.9, groupEnd: end, influence: R(c), endInfluence: R(c), strength: s).lift == 1.5)
        }
        // Speed is zero at groupEnd (rise is held) and at the end of the settle.
        let lift: (Double) -> CGFloat = { LyricEmphasis.glyphMotion(t: $0, groupEnd: 9, influence: R(1), endInfluence: R(1), strength: 1).lift }
        let h = 1e-4
        #expect(abs((lift(9 + h) - lift(9 - h)) / CGFloat(2 * h)) < 3e-3)
        #expect(abs((lift(9.9 + h) - lift(9.9 - h)) / CGFloat(2 * h)) < 3e-3)
    }

    @Test func levelFollowsCoverageThenSettlesToZero() {
        #expect(LyricEmphasis.level(coverage: 0, endCoverage: 1, sinceEnd: -1, settle: 0.9) == 0)
        #expect(LyricEmphasis.level(coverage: 1, endCoverage: 1, sinceEnd: -1, settle: 0.9) == 1)
        #expect(abs(LyricEmphasis.level(coverage: 0.5, endCoverage: 1, sinceEnd: -1, settle: 0.9) - 0.5) < 1e-12)
        #expect(LyricEmphasis.level(coverage: 1, endCoverage: 1, sinceEnd: 0, settle: 0.9) == 1)           // continuous at groupEnd
        #expect(abs(LyricEmphasis.level(coverage: 1, endCoverage: 1, sinceEnd: 0.45, settle: 0.9) - 0.5) < 1e-12)
        #expect(LyricEmphasis.level(coverage: 1, endCoverage: 1, sinceEnd: 0.9, settle: 0.9) == 0)
        #expect(LyricEmphasis.level(coverage: 1, endCoverage: 1, sinceEnd: .nan, settle: 0.9) == 0)
    }

    @Test func peakRangesAreLowered() {
        for s in stride(from: CGFloat(0), through: 1, by: 0.1) {
            #expect(LyricEmphasis.peakLift(strength: s) >= 1.875 - 1e-12 && LyricEmphasis.peakLift(strength: s) <= 2.25 + 1e-12)
            #expect(LyricEmphasis.peakScale(strength: s) >= 1.02 - 1e-12 && LyricEmphasis.peakScale(strength: s) <= 1.04 + 1e-12)
        }
    }

    @Test func neighborWeightsApplyInsideOneGroupOnly() {
        // Only glyph 3 of 8 is fully covered: 1 / 0.35 / 0.12 / 0 by distance.
        var c = [CGFloat](repeating: 0, count: 8)
        c[3] = 1
        let r = LyricEmphasis.influence(coverages: c)
        let want: [CGFloat] = [0, 0.12, 0.35, 1, 0.35, 0.12, 0, 0]
        for i in r.indices { #expect(abs(r[i] - want[i]) < 1e-12) }
        // Another group is a separate call and stays 0.
        #expect(LyricEmphasis.influence(coverages: [0, 0, 0]).allSatisfy { $0 == 0 })
        // Max, not sum: two covered glyphs two apart give the larger weight at the middle one.
        let two = LyricEmphasis.influence(coverages: [1, 0, 1])
        #expect(abs(two[1] - 0.35) < 1e-12)
        #expect(LyricEmphasis.influence(coverages: []).isEmpty)
        #expect(LyricEmphasis.influence(coverages: [.nan, 2]) == [0.35, 1])
        // Lift/scale use r directly.
        let m = LyricEmphasis.glyphMotion(t: 1, groupEnd: 9, influence: 0.35, endInfluence: 1, strength: 1)
        #expect(abs(m.lift - 2.25 * 0.35) < 1e-12 && abs(m.scale - (1 + 0.04 * 0.35)) < 1e-12)
    }

    @Test func influenceIsContinuousAndMonotoneAsTheFrontAdvances() {
        let edge: CGFloat = 20, w: CGFloat = 30
        var prev = [CGFloat](repeating: 0, count: 6)
        var maxStep: CGFloat = 0
        var t = 0.0
        while t <= 4 {
            let front = CGFloat(t) * 60          // 60 pt/s sweep over 6 glyphs
            let c = (0..<6).map { LyricEmphasis.coverage(front: front, left: CGFloat($0) * w, width: w, edge: edge) }
            let r = LyricEmphasis.influence(coverages: c)
            for i in r.indices {
                #expect(r[i] >= prev[i] - 1e-12)
                maxStep = max(maxStep, r[i] - prev[i])
            }
            prev = r
            t += 0.001
        }
        // dc/dt <= 60/(w+edge); smootherstep slope <= 1.875.
        #expect(maxStep <= 1.875 * 60 / (w + edge) * 0.001 * 1.1 + 1e-12)
        #expect(prev.allSatisfy { $0 == 1 })
    }

    @Test func settleStartsFromNeighborInfluenceAndEndsExactly() {
        // A glyph at r = 0.35 (neighbor covered, itself not) settles from its own value without a jump.
        let end = 9.0
        let before = LyricEmphasis.glyphMotion(t: end - 0.001, groupEnd: end, influence: 0.35, endInfluence: 0.35, strength: 1)
        let at = LyricEmphasis.glyphMotion(t: end, groupEnd: end, influence: 0.35, endInfluence: 0.35, strength: 1)
        #expect(abs(at.lift - before.lift) < 1e-9 && abs(at.lift - 2.25 * 0.35) < 1e-9)
        #expect(at.lift < 1.5)                                       // rises toward 1.5, never overshoots
        var prev = at.lift
        var t = end
        while t <= end + 0.9 {
            t += 0.001
            let m = LyricEmphasis.glyphMotion(t: t, groupEnd: end, influence: 0.35, endInfluence: 0.35, strength: 1)
            #expect(m.lift >= prev - 1e-9 && m.lift <= 1.5 + 1e-9)
            prev = m.lift
        }
        let done = LyricEmphasis.glyphMotion(t: end + 0.9, groupEnd: end, influence: 0.35, endInfluence: 0.35, strength: 1)
        #expect(done.lift == 1.5 && done.scale == 1)
    }

    @Test func motionIgnoresBadInput() {
        let m = LyricEmphasis.glyphMotion(t: .nan, groupEnd: 3, influence: R(.nan), endInfluence: R(1), strength: .nan)
        #expect(m.lift == 1.5 && m.scale == 1)
        let z = LyricEmphasis.glyphMotion(t: 2, groupEnd: 3, influence: R(.nan), endInfluence: R(.nan), strength: .nan)
        #expect(z.lift.isFinite && z.scale.isFinite)
    }

    @Test func glowFollowsGroupFillThenFades() {
        #expect(LyricEmphasis.glow(fill: 0, sinceEnd: -1, strength: 1, maxGlow: 0.8) == 0)
        #expect(LyricEmphasis.glow(fill: 1, sinceEnd: -1, strength: 1, maxGlow: 0.8) == 0.8)      // dark
        #expect(abs(LyricEmphasis.glow(fill: 1, sinceEnd: -1, strength: 1, maxGlow: 0.3) - 0.3) < 1e-6)  // light
        #expect(abs(LyricEmphasis.glow(fill: 0.5, sinceEnd: -1, strength: 1, maxGlow: 0.8) - 0.4) < 1e-6)   // e(0.5) = 0.5
        #expect(abs(LyricEmphasis.glow(fill: 1, sinceEnd: 0, strength: 0, maxGlow: 0.8) - 0.48) < 1e-6)
        #expect(LyricEmphasis.glow(fill: 1, sinceEnd: 0.7, strength: 1, maxGlow: 0.8) == 0)
        #expect(LyricEmphasis.glow(fill: 1, sinceEnd: 5, strength: 1, maxGlow: 0.8) == 0)
        let mid = LyricEmphasis.glow(fill: 1, sinceEnd: 0.35, strength: 1, maxGlow: 0.8)
        #expect(mid > 0 && mid < 0.8)
        #expect(LyricEmphasis.glow(fill: .nan, sinceEnd: 0, strength: 1, maxGlow: 0.8) == 0)
        #expect(LyricEmphasis.Metrics.maxGlowDark == 0.8 && LyricEmphasis.Metrics.maxGlowLight == 0.3)
        #expect(LyricEmphasis.Metrics.glowRadiusEm == 0.5)
    }

    @Test func reducedMotionFollowsFillWithoutTimedFadeIn() {
        #expect(LyricEmphasis.reducedGlow(fill: 0, sinceEnd: -1, strength: 1) == 0)
        #expect(LyricEmphasis.reducedGlow(fill: 1, sinceEnd: -1, strength: 1) == 0.25)
        #expect(abs(LyricEmphasis.reducedGlow(fill: 0.5, sinceEnd: -1, strength: 0) - 0.25 * 0.6 * 0.5) < 1e-6)
        #expect(abs(LyricEmphasis.reducedGlow(fill: 1, sinceEnd: 0.15, strength: 1) - 0.125) < 1e-6)    // 0.3 s fade after the end
        #expect(LyricEmphasis.reducedGlow(fill: 1, sinceEnd: 0.3, strength: 1) == 0)
        #expect(abs(LyricEmphasis.level(coverage: 1, endCoverage: 1, sinceEnd: 0.15, settle: LyricEmphasis.Metrics.reducedFade) - 0.5) < 1e-12)
    }

    @Test func characterRangesKeepClustersAndSkipSpaces() {
        let hangul = LyricEmphasis.characterRanges(in: "가나다")
        #expect(hangul == [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1), NSRange(location: 2, length: 1)])
        let combined = LyricEmphasis.characterRanges(in: "e\u{301}a")          // e + combining acute, a
        #expect(combined == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 1)])
        let emoji = LyricEmphasis.characterRanges(in: "a👍🏽b")
        #expect(emoji.count == 3 && emoji[1].length == 4)
        #expect(LyricEmphasis.characterRanges(in: "a b").count == 2)
        #expect(LyricEmphasis.characterRanges(in: "").isEmpty)
    }

    @Test func pixelSpansTileWithoutGaps() {
        let spans = LyricEmphasis.pixelSpans(edges: [0.3, 10.4, 20.6, 31.2], scale: 2)
        #expect(spans.count == 3)
        #expect(spans.first!.lowerBound == 0 && spans.last!.upperBound == 63)
        for i in 1..<spans.count { #expect(spans[i - 1].upperBound == spans[i].lowerBound) }
        #expect(LyricEmphasis.pixelSpans(edges: [1], scale: 2).isEmpty)
    }

    @Test func heldBoundary() {
        #expect(!LyricEmphasis.isHeld(longestSpan: 0.79))
        #expect(LyricEmphasis.isHeld(longestSpan: 0.8))
        let g = LyricEmphasis.Group(range: 0..<1, begin: 0, end: 3, strength: 0.5, longestSpan: 0.79)
        #expect(!g.isHeld)
        var h = g; h.longestSpan = 0.8
        #expect(h.isHeld)
    }

    @Test func heldRiseSpansWholeGroup() {
        #expect(LyricEmphasis.Metrics.riseDuration == 0.6)
        // group 5...9 (4 s): 0 at begin, eased 0.5 at mid, 1 at end
        func a(_ t: Double) -> CGFloat { LyricEmphasis.heldRise(t: t, groupBegin: 5, groupEnd: 9) }
        #expect(a(5) == 0 && a(4) == 0)
        #expect(abs(Double(a(7)) - 0.5) < 1e-9)
        #expect(a(9) == 1 && a(50) == 1)
        #expect(a(5.6) < 0.5)
        #expect(LyricEmphasis.heldRise(t: .nan, groupBegin: 5, groupEnd: 9) == 0)
        // wave influence and glow input are the same a(t) at several times
        for t in [5.5, 6.0, 7.0, 8.0, 9.0] {
            let r = a(t)
            #expect(LyricEmphasis.heldInfluence(count: 3, rise: r).allSatisfy { $0 == r })
            #expect(LyricEmphasis.glow(eased: r, sinceEnd: -1, strength: 1, maxGlow: 0.8)
                    == LyricEmphasis.glow(eased: a(t), sinceEnd: -1, strength: 1, maxGlow: 0.8))
        }
        #expect(LyricEmphasis.glow(eased: a(9), sinceEnd: -1, strength: 1, maxGlow: 0.8)
                > LyricEmphasis.glow(eased: a(7), sinceEnd: -1, strength: 1, maxGlow: 0.8))
        // short held group: minimum 0.6 s
        #expect(abs(Double(LyricEmphasis.heldRise(t: 5.3, groupBegin: 5, groupEnd: 5.4)) - 0.5) < 1e-9)
        #expect(LyricEmphasis.heldRise(t: 5.6, groupBegin: 5, groupEnd: 5.4) == 1)
    }

    @Test func heldGroupGlyphsMoveEqually() {
        let r = LyricEmphasis.heldInfluence(count: 4, rise: 0.4)
        #expect(Set(r).count == 1 && r[0] == 0.4)
        let m = r.map { LyricEmphasis.glyphMotion(t: 1, groupEnd: 5, influence: $0, endInfluence: $0, strength: 0.5) }
        #expect(m.allSatisfy { $0.lift == m[0].lift && $0.scale == m[0].scale })
        // a(group end) = 1: every glyph at the peak, held until the group end, then the usual settle
        let a = LyricEmphasis.heldRise(t: 5, groupBegin: 0, groupEnd: 5)
        let peak = LyricEmphasis.peakLift(strength: 0.5)
        let held = LyricEmphasis.glyphMotion(t: 4.99, groupEnd: 5, influence: a, endInfluence: 1, strength: 0.5)
        #expect(held.lift == peak)
        let settled = LyricEmphasis.glyphMotion(t: 5 + LyricEmphasis.Metrics.settleDuration, groupEnd: 5, influence: 1, endInfluence: 1, strength: 0.5)
        #expect(settled.lift == 1.5 && settled.scale == 1)
        // eased variants agree with the raw ones for the same eased value
        let g: CGFloat = 0.4, e = CGFloat(LyricEmphasis.ease(0.4))
        #expect(LyricEmphasis.glow(fill: g, sinceEnd: -1, strength: 1, maxGlow: 0.8) == LyricEmphasis.glow(eased: e, sinceEnd: -1, strength: 1, maxGlow: 0.8))
        #expect(LyricEmphasis.level(coverage: g, endCoverage: 1, sinceEnd: -1, settle: 0.9) == LyricEmphasis.level(eased: e, endEased: 1, sinceEnd: -1, settle: 0.9))
        // ordinary per-glyph influence differs between glyphs
        let o = LyricEmphasis.influence(coverages: [1, 0.5, 0, 0])
        #expect(Set(o).count > 1)
    }
}
