import AppKit
import QuartzCore
import Testing
@testable import FloatingLyric

/// F25: line moves must not restart while they run. Synthetic lines only; time is driven by hand.
@MainActor
@Suite struct LyricsViewMotionTests {
    /// Lines 2 s long with 0.1 s between sung end and next begin (a "fast" connected move).
    private func makeView() -> LyricsView {
        _ = NSApplication.shared
        let prefs = LyricPreferences(defaults: UserDefaults(suiteName: "FloatingLyricMotion-\(UUID().uuidString)")!)
        let view = LyricsView(preferences: prefs)
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
        let lines = (0..<8).map { i -> LyricLine in
            let b = Double(i) * 2.1
            return LyricLine(begin: b, end: b + 2, key: nil, agent: "v1",
                             words: [LyricWord(text: "alpha", begin: b, end: b + 2, trailingSpace: false)],
                             background: [], translation: nil, transliteration: nil)
        }
        view.show(document: LyricsDocument(timing: .word, language: nil, lines: lines), emptyState: .none)
        view.step(at: 1, jump: true)
        return view
    }

    @Test func lingeringOnlyChangeKeepsRunningMoves() {
        let view = makeView()
        view.step(at: 1.85, jump: false)            // center -> line 1, line 0 lingers
        let before = (0..<4).map { view.positionAnimations(forLine: $0) }
        #expect(!before[1].isEmpty)
        view.step(at: 2.05, jump: false)            // line 0 stops lingering, same center
        for i in 0..<4 {
            let after = view.positionAnimations(forLine: i)
            #expect(Set(after.keys) == Set(before[i].keys))
            for (k, a) in after { #expect(a === before[i][k]) }
        }
    }

    @Test func nextCenterChangeStacksOnRunningMove() {
        let view = makeView()
        view.step(at: 1.85, jump: false)
        let first = view.positionAnimations(forLine: 1)
        #expect(first.count == 1)
        view.step(at: 3.95, jump: false)            // center -> line 2 while line 1's move still runs
        let second = view.positionAnimations(forLine: 1)
        #expect(second.count == 2)
        for (k, a) in first { #expect(second[k] === a) }
        #expect(second.values.allSatisfy { ($0 as? CABasicAnimation)?.isAdditive == true })
    }

    @Test func jumpRemovesStackedMoves() {
        let view = makeView()
        view.step(at: 1.85, jump: false)
        view.step(at: 3.95, jump: false)
        view.step(at: 12, jump: true)
        for i in 0..<8 { #expect(view.positionAnimations(forLine: i).isEmpty) }
    }

    @Test func lingeringEndKeepsMoveDuration() {
        let view = makeView()
        view.step(at: 1.85, jump: false)
        #expect(view.lineMoveDuration == LyricsLayout.Metrics.fastLineTransition)
        view.step(at: 2.05, jump: false)            // used to recompute from == to -> slow
        #expect(view.lineMoveDuration == LyricsLayout.Metrics.fastLineTransition)
    }
}
