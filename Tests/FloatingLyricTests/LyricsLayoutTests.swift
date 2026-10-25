import Foundation
import Testing
@testable import FloatingLyric

@Suite struct LyricsLayoutTests {
    private func word(_ b: TimeInterval, _ e: TimeInterval) -> LyricWord {
        LyricWord(text: "alpha", begin: b, end: e, trailingSpace: true)
    }
    private func line(_ b: TimeInterval, _ e: TimeInterval) -> LyricLine {
        LyricLine(begin: b, end: e, key: nil, agent: "v1", words: [word(b, e)], background: [],
                  translation: nil, transliteration: nil)
    }
    private func input(rows: Int = 10, active: Int = 5, context: LyricPreferences.Context = .around,
                       n: Int = 5, blur: Bool = true, scrolling: Bool = false) -> LyricsLayout.Input {
        LyricsLayout.Input(heights: Array(repeating: 20, count: rows), activeRow: active, context: context,
                           visibleLines: n, spacing: 10, viewportHeight: 5 * 30 + 20, topPadding: 10,
                           bottomPadding: 10, blurInactive: blur, isUserScrolling: scrolling,
                           visibilityMargin: 30)
    }

    @Test func anchorSlots() {
        let expected: [(Int, Int)] = [(1, 0), (2, 0), (3, 1), (5, 2), (9, 4)]
        for (n, slot) in expected {
            #expect(LyricsLayout.anchorSlot(context: .around, visibleLines: n) == slot)
            #expect(LyricsLayout.anchorSlot(context: .upcomingOnly, visibleLines: n) == 0)
        }
    }

    @Test func activeRowLandsOnAnchorSlot() {
        let i = input(n: 5)
        let s = LyricsLayout.styles(i)
        // pitch = (170 - 20) / 5 = 30; slot 2 -> y = 10 + 60
        #expect(abs(s[5].y - 70) < 1e-9)
        #expect(abs(LyricsLayout.styles(input(context: .upcomingOnly))[5].y - 10) < 1e-9)
    }

    @Test func opacityAndScaleByDistance() {
        let s = LyricsLayout.styles(input())
        #expect(s[5].opacity == 1 && s[5].scale == 1)
        #expect(s[6].opacity == LyricsLayout.Metrics.inactiveOpacity)
        #expect(s[4].opacity == LyricsLayout.Metrics.pastOpacity)
        #expect(s[6].scale == LyricsLayout.Metrics.inactiveScale)
    }

    @Test func blurGrowsAndCapsAtFour() {
        let s = LyricsLayout.styles(input(rows: 20, active: 0))
        #expect(s[0].blurRadius == 0)
        #expect(s[1].blurRadius == 1)
        #expect(s[3].blurRadius == 3)
        #expect(s[4].blurRadius == 4)
        #expect(s[12].blurRadius == 4)
    }

    @Test func blurOffWhenDisabledOrScrolling() {
        #expect(LyricsLayout.styles(input(blur: false)).allSatisfy { $0.blurRadius == 0 })
        #expect(LyricsLayout.styles(input(scrolling: true)).allSatisfy { $0.blurRadius == 0 })
    }

    @Test func rowsFarOutsideViewportAreHidden() {
        let s = LyricsLayout.styles(input(rows: 30, active: 15))
        #expect(s[15].isVisible)
        #expect(s[0].isVisible == false)
        #expect(s[29].isVisible == false)
        // One row beyond the viewport edge is still kept (margin).
        let visible = s.indices.filter { s[$0].isVisible }
        #expect(visible.count >= 5 && visible.count <= 9)
    }

    @Test func zeroHeightRowsTakeNoSpace() {
        let tops = LyricsLayout.contentTops(heights: [20, 0, 20], spacing: 10)
        #expect(tops == [0, 30, 30])
    }

    @Test func activeLineIndexEdges() {
        let lines = [line(10, 14), line(20, 24), line(30, 34)]
        #expect(LyricsLayout.activeLineIndex(for: 0, lines: lines) == nil)
        #expect(LyricsLayout.activeLineIndex(for: 9.99, lines: lines) == nil)
        #expect(LyricsLayout.activeLineIndex(for: 10, lines: lines) == 0)
        #expect(LyricsLayout.activeLineIndex(for: 17, lines: lines) == 0)   // between lines
        #expect(LyricsLayout.activeLineIndex(for: 20, lines: lines) == 1)
        #expect(LyricsLayout.activeLineIndex(for: 500, lines: lines) == 2)  // after last
        #expect(LyricsLayout.activeLineIndex(for: 5, lines: []) == nil)
    }

    @Test func interludeBeforeFirstLine() {
        let lines = [line(10, 14), line(16, 20)]
        let info = LyricsLayout.interludeInfo(position: 5, lines: lines)
        #expect(info?.beforeLine == 0)
        #expect(abs((info?.progress ?? -1) - 0.5) < 1e-9)
        #expect(LyricsLayout.interludeInfo(position: 10, lines: lines) == nil)
    }

    @Test func shortIntroHasNoInterlude() {
        let lines = [line(3.9, 8)]
        #expect(LyricsLayout.interludeInfo(position: 1, lines: lines) == nil)
        #expect(LyricsLayout.interludeLines(lines: lines).isEmpty)
    }

    @Test func interludeBetweenLines() {
        let lines = [line(10, 14), line(24, 28)]   // gap 14...24 = 10 s
        #expect(LyricsLayout.interludeInfo(position: 12, lines: lines) == nil)           // still singing
        #expect(LyricsLayout.interludeInfo(position: 14, lines: lines)?.progress == 0)
        let mid = LyricsLayout.interludeInfo(position: 19, lines: lines)
        #expect(mid?.beforeLine == 1)
        #expect(abs((mid?.progress ?? -1) - 0.5) < 1e-9)
        #expect(LyricsLayout.interludeInfo(position: 24, lines: lines) == nil)
        #expect(LyricsLayout.interludeInfo(position: 100, lines: lines) == nil)          // after last line
        #expect(LyricsLayout.interludeLines(lines: lines) == [0, 1])   // 0 = the long intro
    }

    @Test func shortGapBetweenLinesIsNotAnInterlude() {
        let lines = [line(10, 14), line(17.9, 20)]
        #expect(LyricsLayout.interludeInfo(position: 15, lines: lines) == nil)
    }

    @Test func wordProgressEdges() {
        let w = word(2, 4)
        #expect(LyricsLayout.wordProgress(t: 1, word: w) == 0)
        #expect(LyricsLayout.wordProgress(t: 3, word: w) == 0.5)
        #expect(LyricsLayout.wordProgress(t: 9, word: w) == 1)
        let instant = word(2, 2)
        #expect(LyricsLayout.wordProgress(t: 1.9, word: instant) == 0)
        #expect(LyricsLayout.wordProgress(t: 2, word: instant) == 1)
        let inverted = word(5, 4)
        #expect(LyricsLayout.wordProgress(t: 6, word: inverted) == 1)
    }

    // MARK: F17 overlap

    @Test func sungEndUsesBodyWordsOnly() {
        var l = line(5, 8)
        l.words = [word(5, 6), word(6, 10)]
        l.background = [word(6, 12)]
        #expect(LyricsLayout.sungEnd(of: l) == 10)
        l.words = []
        #expect(LyricsLayout.sungEnd(of: l) == 8)
    }

    @Test func overlappingEarlierLineStaysLingeringUntilSungEnd() {
        var first = line(5, 9)
        first.words = [word(5, 9), word(9, 10)]
        let lines = [first, line(9.5, 12)]
        #expect(LyricsLayout.activeLineIndex(for: 9.7, lines: lines) == 1)
        #expect(LyricsLayout.lingeringLines(position: 9.7, lines: lines) == [0])
        #expect(LyricsLayout.lingeringLines(position: 10.1, lines: lines).isEmpty)
        #expect(LyricsLayout.wordProgress(t: LyricsLayout.sungEnd(of: first), word: first.words[1]) == 1)
    }

    @Test func noOverlapMeansNoLingering() {
        let lines = [line(0, 2), line(3, 5), line(6, 8)]
        for t in stride(from: 0.0, through: 9.0, by: 0.25) {
            #expect(LyricsLayout.lingeringLines(position: t, lines: lines).isEmpty)
        }
        #expect(LyricsLayout.lingeringLines(position: -1, lines: lines).isEmpty)
    }

    // MARK: Line lead (PLAN 12.35)

    @Test func leadSwitchesFocusEarlyAndKeepsPreviousLingering() {
        let lead = 0.3
        let lines = [line(0, 10), line(10, 14)]
        let early = LyricsLayout.focus(at: 9.8, lead: lead, lines: lines)   // 0.2 s ahead
        #expect(early.activeLine == 1 && early.lingering == [0])
        let tooEarly = LyricsLayout.focus(at: 9.6, lead: lead, lines: lines) // 0.4 s ahead
        #expect(tooEarly.activeLine == 0 && tooEarly.lingering.isEmpty)
    }

    @Test func nonOverlappingPreviousBecomesPastAfterEnd() {
        let lines = [line(0, 2), line(2.2, 5)]
        let during = LyricsLayout.focus(at: 1.95, lead: 0.3, lines: lines)
        #expect(during.activeLine == 1 && during.lingering == [0])
        let after = LyricsLayout.focus(at: 2.05, lead: 0.3, lines: lines)
        #expect(after.activeLine == 1 && after.lingering.isEmpty)
    }

    @Test func interludeProgressUsesRealTime() {
        let lines = [line(0, 2), line(12, 14)]
        let r = LyricsLayout.focus(at: 7, lead: 0.3, lines: lines)   // gap 2...12
        #expect(r.interludeBefore == 1 && abs(r.progress - 0.5) < 1e-9)
        let early = LyricsLayout.focus(at: 11.8, lead: 0.3, lines: lines)
        #expect(early.activeLine == 1 && early.interludeBefore == nil)
        let start = LyricsLayout.focus(at: 1.8, lead: 0.3, lines: lines) // selected early, progress clamped
        #expect(start.interludeBefore == 1 && start.progress == 0 && start.lingering == [0])
    }
}
