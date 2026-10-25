import AppKit
import Testing
@testable import FloatingLyric

/// Layer structure of one line: plates, emphasis glyphs, Reduce Motion, HDR switch. Synthetic text only.
@MainActor
@Suite struct LyricLineLayerTests {
    private func makeLayer(timing: LyricsDocument.Timing = .word, longDuration: TimeInterval = 3,
                           background: [LyricWord] = []) -> LyricLineLayer {
        let words = [LyricWord(text: "가나다라", begin: 10, end: 10 + longDuration, trailingSpace: true),
                     LyricWord(text: "beta", begin: 10 + longDuration, end: 10.5 + longDuration, trailingSpace: false)]
        let line = LyricLine(begin: 10, end: 10.5 + longDuration, key: nil, agent: "v1", words: words,
                             background: background, translation: nil, transliteration: nil)
        let layer = LyricLineLayer(line: line, timing: timing, width: 400, fontSize: 24, rightAligned: false,
                                   translation: nil, palette: LyricPalette(glass: .regular),
                                   appearance: NSAppearance(named: .darkAqua)!)
        layer.contentsScale = 2
        layer.loadContent()
        return layer
    }

    /// "가나" 1 s + "다라마" 4 s + "바사" 1 s glued together (s = 1), then a short word after a space.
    private func makeGroupLayer(reduced: Bool = false, width: CGFloat = 400, appearance: NSAppearance = NSAppearance(named: .darkAqua)!) -> LyricLineLayer {
        let words = [LyricWord(text: "가나", begin: 10, end: 11, trailingSpace: false),
                     LyricWord(text: "다라마", begin: 11, end: 15, trailingSpace: false),
                     LyricWord(text: "바사", begin: 15, end: 16, trailingSpace: true),
                     LyricWord(text: "beta", begin: 16, end: 16.5, trailingSpace: false)]
        let line = LyricLine(begin: 10, end: 16.5, key: nil, agent: "v1", words: words,
                             background: [], translation: nil, transliteration: nil)
        let layer = LyricLineLayer(line: line, timing: .word, width: width, fontSize: 24, rightAligned: false,
                                   translation: nil, palette: LyricPalette(glass: .regular),
                                   appearance: appearance)
        layer.contentsScale = 2
        layer.motionReduced = reduced
        layer.loadContent()
        layer.setState(.active, animated: false)
        return layer
    }

    /// Same text, but every span is 0.75 s (< heldSpanMin): an ordinary group, per-glyph motion.
    private func makeOrdinaryGroupLayer() -> LyricLineLayer {
        let words = [LyricWord(text: "가나", begin: 10, end: 10.75, trailingSpace: false),
                     LyricWord(text: "다라마", begin: 10.75, end: 11.5, trailingSpace: false),
                     LyricWord(text: "바사", begin: 11.5, end: 12.25, trailingSpace: true),
                     LyricWord(text: "beta", begin: 12.25, end: 12.75, trailingSpace: false)]
        let line = LyricLine(begin: 10, end: 12.75, key: nil, agent: "v1", words: words,
                             background: [], translation: nil, transliteration: nil)
        let layer = LyricLineLayer(line: line, timing: .word, width: 400, fontSize: 24, rightAligned: false,
                                   translation: nil, palette: LyricPalette(glass: .regular),
                                   appearance: NSAppearance(named: .darkAqua)!)
        layer.contentsScale = 2
        layer.loadContent()
        layer.setState(.active, animated: false)
        return layer
    }

    private func glyphCount(_ l: LyricLineLayer) -> Int { l.blocks.flatMap(\.fragments).reduce(0) { $0 + $1.glyphs.count } }

    @Test func plateStructure() throws {
        let l = makeLayer()
        let f = try #require(l.blocks.first?.fragments.first)
        let container = try #require(f.container)
        #expect(container.sublayers?.count == 2)
        #expect(f.fill?.sublayers?.first === f.bright)
        #expect(f.bright?.mask != nil)
        #expect(f.bright?.backgroundColor != nil)
    }

    @Test func glyphsLiveOnlyWhileActive() {
        let l = makeLayer()
        #expect(glyphCount(l) == 0)
        l.setState(.active, animated: false)
        #expect(glyphCount(l) == 4)               // 가나다라; "beta" is too short
        l.setPosition(11.5)
        #expect(glyphCount(l) == 4)
        l.setState(.past, animated: false)
        #expect(glyphCount(l) == 0)
        #expect(l.blocks.first?.fragments.first?.container?.isHidden == false)
    }

    @Test func glyphsTileTheWordPiece() throws {
        let l = makeLayer()
        l.setState(.active, animated: false)
        let f = try #require(l.blocks.first?.fragments.first)
        let frames = f.glyphs.map(\.container.frame)
        for i in 1..<frames.count { #expect(abs(frames[i - 1].maxX - frames[i].minX) < 1e-6) }
        #expect(abs(frames.first!.minX - f.container!.frame.minX) < 1e-6)
        #expect(abs(frames.last!.maxX - f.container!.frame.maxX) < 1e-6)
        #expect(f.container?.isHidden == true)
    }

    @Test func noGlyphsForShortWordsLineTimingOrReducedMotion() {
        let short = makeLayer(longDuration: 0.8)
        short.setState(.active, animated: false)
        #expect(glyphCount(short) == 0)
        let lineTiming = makeLayer(timing: .line)
        lineTiming.setState(.active, animated: false)
        #expect(glyphCount(lineTiming) == 0)
        let reduced = makeLayer()
        reduced.motionReduced = true
        reduced.setState(.active, animated: false)
        #expect(glyphCount(reduced) == 0)
    }

    @Test func backgroundVocalsAreNotEmphasized() {
        let bg = [LyricWord(text: "가나다", begin: 10, end: 14, trailingSpace: false)]
        let l = makeLayer(longDuration: 0.5, background: bg)
        l.setState(.active, animated: false)
        #expect(glyphCount(l) == 0)
    }

    @Test func waveMovesGlyphsAndSettles() throws {
        let l = makeLayer()
        l.setState(.active, animated: false)
        l.setPosition(10.01)
        let f = try #require(l.blocks.first?.fragments.first)
        #expect(f.glyphs.first!.container.shadowOpacity >= 0)
        l.setPosition(14)                         // group done (13 + 0.7 s), everything settled
        for g in f.glyphs {
            #expect(g.lastMotion?.lift == 1.5 && g.lastMotion?.scale == 1)
            #expect(g.fill.mask == nil && !g.fill.isHidden)
        }
        l.setPosition(9)                          // seek back before the word
        #expect(f.glyphs.allSatisfy { $0.lastMotion?.lift == 0 && $0.fill.isHidden })
    }

    @Test func hdrOnlyOnBrightLayers() throws {
        let l = makeLayer()
        l.setState(.active, animated: false)
        let f = try #require(l.blocks.first?.fragments.first)
        let sdr = f.bright?.backgroundColor
        l.setDynamicRange(headroom: 1.8)
        #expect(f.bright?.preferredDynamicRange == .constrainedHigh)
        #expect(f.bright?.backgroundColor != sdr)
        #expect(f.container?.preferredDynamicRange == .standard)
        #expect(f.dim?.preferredDynamicRange == .standard)
        l.setDynamicRange(headroom: nil)
        #expect(f.bright?.preferredDynamicRange == .standard)
        l.setDynamicRange(headroom: 1.8)
        l.setState(.past, animated: false)          // other lines stay SDR
        #expect(f.bright?.preferredDynamicRange == .standard)
    }

    @Test func groupSpansWaveWithTheirFillAndSettleTogether() {
        let l = makeGroupLayer()
        #expect(glyphCount(l) == 7)               // 가나 다라마 바사; "beta" is a short group
        let glyphs = l.blocks.flatMap(\.fragments).flatMap(\.glyphs)
        l.setPosition(10)                         // held group v2: a(0) = 0, nothing lifted yet
        #expect(glyphs.allSatisfy { $0.lastMotion?.lift == 0 })
        l.setPosition(10.6)                       // rise spans the whole group (6 s): still low at 0.6 s
        #expect(glyphs.allSatisfy { ($0.lastMotion?.lift ?? 9) < 2.25 * 0.1 })
        l.setPosition(13)                         // a(3 / 6) = 0.5 for every glyph, fill is mid-way
        let g = LyricEmphasis.groupFill(glyphs.map { (coverage: $0.coverage, width: $0.spec.rect.width) })
        #expect(g > 0.2 && g < 0.8)
        #expect(glyphs.allSatisfy { abs(Double($0.lastMotion?.lift ?? -1) - 2.25 * 0.5) < 1e-9 })
        l.setPosition(15.999)                     // fill reaches the end: every glyph at the peak, held
        #expect(glyphs.allSatisfy { abs(($0.lastMotion?.lift ?? 0) - 2.25) < 1e-2 })
        l.setPosition(16.3)                       // all settle together
        let settling = glyphs.map { $0.lastMotion?.lift ?? -1 }
        #expect(settling.allSatisfy { $0 >= 1.5 && $0 <= 2.25 } && Set(settling).count == 1)
        l.setPosition(17)
        #expect(glyphs.allSatisfy { $0.lastMotion?.lift == 1.5 && $0.lastMotion?.scale == 1 })
    }

    @Test func groupGlowIsSharedAndFades() {
        let l = makeGroupLayer()
        l.setPosition(13)
        let glyphs = l.blocks.flatMap(\.fragments).flatMap(\.glyphs)
        let opacities = Set(glyphs.map(\.container.shadowOpacity))
        #expect(opacities.count == 1 && (opacities.first ?? 0) > 0.2)
        l.setPosition(16.3)                       // still fading (0.7 s after groupEnd 16)
        #expect(glyphs.allSatisfy { $0.container.shadowOpacity > 0 })
        l.setPosition(16.8)
        #expect(glyphs.allSatisfy { $0.container.shadowOpacity == 0 })
    }

    @Test func glyphsHaveOutlineShadowPathInsideContainer() throws {
        let l = makeGroupLayer()
        let glyphs = l.blocks.flatMap(\.fragments).flatMap(\.glyphs)
        #expect(glyphs.count == 7)
        for g in glyphs {
            let path = try #require(g.container.shadowPath)
            let box = path.boundingBoxOfPath
            #expect(!path.isEmpty && box.width > 1 && box.height > 1)
            #expect(g.container.bounds.insetBy(dx: -0.5, dy: -0.5).contains(box))
            #expect(g.container.shadowRadius == 12)                 // 0.5 x 24 pt
        }
        // Word pieces of the group (fallback when a glyph split fails) carry the path too; plain words do not.
        let frags = l.blocks.flatMap(\.fragments)
        #expect(frags.filter { $0.groupIndex != nil }.allSatisfy { $0.container?.shadowPath != nil })
        #expect(frags.filter { $0.groupIndex == nil }.allSatisfy { $0.container?.shadowPath == nil })
    }

    @Test func glowStrengthFollowsAppearance() {
        let dark = makeGroupLayer()
        dark.setPosition(13)
        let light = makeGroupLayer(appearance: NSAppearance(named: .aqua)!)
        light.setPosition(13)
        let d = dark.blocks.flatMap(\.fragments).flatMap(\.glyphs).first!.container.shadowOpacity
        let li = light.blocks.flatMap(\.fragments).flatMap(\.glyphs).first!.container.shadowOpacity
        #expect(d > li && abs(d / li - 0.8 / 0.3) < 1e-4)
    }

    @Test func glyphLiftIsTheNeighborWeightedSmootherstepOfCoverage() {
        let l = makeOrdinaryGroupLayer()
        let frags = l.blocks.flatMap(\.fragments).filter { !$0.glyphs.isEmpty }
        let all = frags.flatMap(\.glyphs)
        for t in [10.0, 10.3, 10.9, 11.2, 11.8, 12.1, 12.24] {
            l.setPosition(t)
            let r = LyricEmphasis.influence(coverages: all.map(\.coverage))
            for f in frags {
                let word = l.blocks[0].words[f.wordIndex]
                let edge = 24 * LyricEmphasis.edgeEm(duration: word.end - word.begin)
                let front = LyricsLayout.wordProgress(t: t, word: word) * (f.wordWidth + edge)
                for g in f.glyphs {
                    let c = LyricEmphasis.coverage(front: front, left: g.spec.offset, width: g.spec.rect.width, edge: edge)
                    #expect(abs(g.coverage - c) < 1e-12)
                    let i = all.firstIndex { $0 === g }!
                    #expect(abs((g.lastMotion?.lift ?? -1) - 2.25 * r[i]) < 1e-9)
                    #expect(r[i] >= CGFloat(LyricEmphasis.ease(Double(c))) - 1e-12)
                }
            }
        }
    }

    @Test func wrappedGroupGlowUsesFillRatioOverAllPieces() {
        let l = makeGroupLayer(width: 100)
        let frags = l.blocks[0].fragments
        #expect(frags.count > 4)                                // the glued group wraps over several text lines
        let glyphs = l.blocks.flatMap(\.fragments).flatMap(\.glyphs)
        #expect(glyphs.count == 7)
        l.setPosition(13)
        let g = LyricEmphasis.groupFill(glyphs.map { (coverage: $0.coverage, width: $0.spec.rect.width) })
        #expect(g > 0.2 && g < 0.8)
        let expected = LyricEmphasis.glow(eased: 0.5, sinceEnd: -3, strength: 1, maxGlow: 0.8)   // held: a(3 / 6 s) = 0.5, same a as the wave
        #expect(abs(glyphs[0].container.shadowOpacity - expected) < 1e-5)
        #expect(Set(glyphs.map(\.container.shadowOpacity)).count == 1)
        // The filled share of the piece widths is what the glow sees, whichever text line a piece sits on.
        let total = glyphs.reduce(0) { $0 + $1.spec.rect.width }
        let covered = glyphs.reduce(0) { $0 + $1.coverage * $1.spec.rect.width }
        #expect(abs(g - covered / total) < 1e-9)
    }

    @Test func glyphBrightnessFollowsCoverage() throws {
        let l = makeGroupLayer()
        l.setDynamicRange(headroom: 1.6)
        l.setPosition(10.01)
        let glyphs = l.blocks.flatMap(\.fragments).flatMap(\.glyphs)
        func white(_ g: LyricLineLayer.Glyph) throws -> CGFloat {
            try #require(g.bright.backgroundColor?.components)[0]
        }
        #expect(abs(try white(glyphs[4]) - 1.03) < 1e-6)       // not started yet
        l.setPosition(13)                                       // held group v2: brightness = a(t) = 0.5, same for all
        let half = LyricHDR.level(progress: 0.5, strength: 1, headroom: 1.6)
        for gl in glyphs { #expect(abs(try white(gl) - half) < 1e-6) }
        let g = LyricEmphasis.groupFill(glyphs.map { (coverage: $0.coverage, width: $0.spec.rect.width) })
        #expect(g > 0.2 && g < 0.8)                             // fill is mid-way at 13 as well
        l.setPosition(16)
        #expect(abs(try white(glyphs[0]) - 1.6) < 1e-6)        // s = 1 peak
        l.setPosition(17)
        #expect(abs(try white(glyphs[0]) - 1.03) < 1e-6)       // settled back
    }

    @Test func plainClearModeRaisesBaseAndPeakAndClamps() throws {
        let l = makeGroupLayer()
        l.setDynamicRange(headroom: 2.0, mode: .plainClear)
        let glyphs = l.blocks.flatMap(\.fragments).flatMap(\.glyphs)
        func white(_ g: LyricLineLayer.Glyph) throws -> CGFloat { try #require(g.bright.backgroundColor?.components)[0] }
        l.setPosition(10.01)
        #expect(abs(try white(glyphs[4]) - 1.35) < 1e-6)
        let f = try #require(l.blocks.first?.fragments.last)           // "beta": plain word, base color
        #expect(abs(try #require(f.bright?.backgroundColor?.components)[0] - 1.35) < 1e-6)
        l.setPosition(16)
        #expect(abs(try white(glyphs[0]) - 2.0) < 1e-6)               // s = 1 peak of the mode
        l.setDynamicRange(headroom: 1.3, mode: .plainClear)            // potential clamp
        #expect(abs(try white(glyphs[0]) - 1.3) < 1e-6)
        #expect(abs(try #require(f.bright?.backgroundColor?.components)[0] - 1.3) < 1e-6)
    }

    @Test func modeChangeRecolorsWithoutRerender() throws {
        let l = makeGroupLayer()
        l.setDynamicRange(headroom: 1.6, mode: .standard)
        l.setPosition(16)
        let block = try #require(l.blocks.first)
        let dim = try #require(block.dimImage), alpha = try #require(block.alphaImage)
        let glyphs = block.fragments.flatMap(\.glyphs)
        let containers = glyphs.map(\.container)
        let before = try #require(glyphs[0].bright.backgroundColor?.components)[0]
        l.setDynamicRange(headroom: 2.0, mode: .plainClear)
        #expect(block.dimImage === dim && block.alphaImage === alpha)   // same bitmaps
        #expect(zip(block.fragments.flatMap(\.glyphs), containers).allSatisfy { $0.container === $1 })   // same layers
        let after = try #require(glyphs[0].bright.backgroundColor?.components)[0]
        #expect(abs(before - 1.6) < 1e-6 && abs(after - 2.0) < 1e-6)
        l.setDynamicRange(headroom: 1.6, mode: .standard)
        #expect(abs(try #require(glyphs[0].bright.backgroundColor?.components)[0] - 1.6) < 1e-6)
        #expect(block.dimImage === dim)
    }

    @Test func reducedMotionFollowsFillForGlowAndBrightness() throws {
        let l = makeGroupLayer(reduced: true)
        #expect(glyphCount(l) == 0)
        l.setDynamicRange(headroom: 1.6)
        let f = try #require(l.blocks.first?.fragments.first)         // 가나, fully sung at 13
        l.setPosition(9)
        #expect(f.container?.shadowOpacity == 0)
        l.setPosition(10.5)
        let early = f.container?.shadowOpacity ?? -1
        l.setPosition(13)
        let later = f.container?.shadowOpacity ?? -1
        #expect(early > 0 && later > early && later <= 0.25 + 1e-6)   // follows a(t), never above the fixed amplitude
        #expect(f.container?.transform.m42 == 0 || f.container?.transform.m42 == nil)
        let c = try #require(f.bright?.backgroundColor?.components)
        #expect(abs(c[0] - 1.6) < 1e-6)
        l.setPosition(16.4)                                            // 0.3 s fade after the group ended
        #expect(f.container?.shadowOpacity == 0)
        #expect(abs(try #require(f.bright?.backgroundColor?.components)[0] - 1.03) < 1e-6)
    }

    @Test func unfilledColorFollowsRenderAppearance() throws {
        let glass = GlassAppearance(isClear: true, blurHidden: true, blurOpacity: 0.58, pinnedDark: false, solidElements: true)
        let palette = LyricPalette(glass: glass)
        let light = LyricPalette.resolve(palette.unfilled, in: NSAppearance(named: .aqua)!)
        let dark = LyricPalette.resolve(palette.unfilled, in: NSAppearance(named: .darkAqua)!)
        #expect(abs(light.alpha - 0.35) < 1e-6 && abs(dark.alpha - 0.35) < 1e-6)
        #expect(try #require(light.components)[0] < 0.1)        // black on Light
        #expect(try #require(dark.components)[0] > 0.9)         // white on Dark
        // Same through the drawing-appearance path a view under a different system appearance takes.
        var viaCurrent: CGColor?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { viaCurrent = palette.unfilled.cgColor }
        #expect(try #require(viaCurrent?.components)[0] < 0.1)
    }
}
