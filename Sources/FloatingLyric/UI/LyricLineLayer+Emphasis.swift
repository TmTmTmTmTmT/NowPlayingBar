import AppKit
import QuartzCore
import CoreText

/// Plates, HDR colors, glow and the glyph wave of `LyricLineLayer` (PLAN 4.1 v4-v9).
extension LyricLineLayer {
    /// One glyph (composed character sequence) of an emphasized group, on one text line.
    struct GlyphSpec {
        let rect: CGRect           // block space
        let offset: CGFloat        // from the start of the word, along its text
        let outline: CGPath        // glyph outline, block space (glow shadowPath source)
    }

    /// Live layers of a glyph; exist only while the line is active.
    final class Glyph {
        let spec: GlyphSpec
        let container: CALayer
        let fill: CALayer
        let bright: CALayer
        var group: LyricEmphasis.Group
        /// Fill coverage of the latest frame (feeds the group glow) and at `group.end` (start of the settle).
        var coverage: CGFloat = 0
        var endCoverage: CGFloat = 1
        var lastMotion: (lift: CGFloat, scale: CGFloat)?
        var lastMultiplier: CGFloat = 0
        var lastGlow: Float = -1
        init(spec: GlyphSpec, container: CALayer, fill: CALayer, bright: CALayer, group: LyricEmphasis.Group) {
            self.spec = spec; self.container = container; self.fill = fill; self.bright = bright; self.group = group
        }
    }

    /// An emphasized word group of the main vocal; owns the group-level glow.
    final class GroupState {
        let group: LyricEmphasis.Group
        var fragments: [Fragment] = []
        var glyphs: [Glyph] = []
        var lastGlow: Float = -1
        init(_ group: LyricEmphasis.Group) { self.group = group }
    }

    /// Splits a word piece into composed character sequences. Empty (= no emphasis for the piece)
    /// unless the sequences tile the piece left to right without gaps.
    func glyphSpecs(text: NSString, part: NSRange, line: CTLine, origin: CGPoint,
                    rect: CGRect, wordOffset: CGFloat) -> [GlyphSpec] {
        let seqs = LyricEmphasis.characterRanges(in: text.substring(with: part))
        guard !seqs.isEmpty, seqs.first!.location == 0, NSMaxRange(seqs.last!) == part.length else { return [] }
        for i in 1..<seqs.count where seqs[i].location != NSMaxRange(seqs[i - 1]) { return [] }
        let xs = (seqs.map { $0.location } + [part.length]).map {
            origin.x + CTLineGetOffsetForStringIndex(line, part.location + $0, nil)
        }
        for i in 1..<xs.count where !(xs[i] > xs[i - 1]) { return [] }
        guard xs.first! >= rect.minX - 0.01, xs.last! <= rect.maxX + 0.01 else { return [] }
        return (0..<seqs.count).map { i in
            GlyphSpec(rect: CGRect(x: xs[i], y: rect.minY, width: xs[i + 1] - xs[i], height: rect.height),
                      offset: wordOffset + xs[i] - rect.minX,
                      outline: Self.outline(line: line, origin: origin,
                                            range: NSRange(location: part.location + seqs[i].location, length: seqs[i].length)))
        }
    }

    /// Outline of the glyphs of `line` whose string index lies in `range`, in block space
    /// (`origin` is the line origin). Built once per piece; used as the glow `shadowPath`.
    static func outline(line: CTLine, origin: CGPoint, range: NSRange) -> CGPath {
        let path = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            var indices = [CFIndex](repeating: 0, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let fontRef = attrs[kCTFontAttributeName as String] else { continue }
            let font = fontRef as! CTFont
            for i in 0..<n where indices[i] >= range.location && indices[i] < NSMaxRange(range) {
                guard let g = CTFontCreatePathForGlyph(font, glyphs[i], nil) else { continue }
                path.addPath(g, transform: CGAffineTransform(translationX: origin.x + positions[i].x, y: origin.y + positions[i].y))
            }
        }
        return path
    }

    struct Plates {
        let container: CALayer, dim: CALayer, fill: CALayer, bright: CALayer
    }

    func blockBottom(_ block: Block) -> CGFloat {
        Metrics.inset + height - (block.top + block.size.height)
    }

    /// container > dim (unfilled crop) + fill (gradient mask) > bright (solid color, masked by the glyph alpha crop).
    func makePlates(block: Block, crop: CGRect, outline: CGPath? = nil) -> Plates? {
        guard let dimImage = block.dimImage, let alphaImage = block.alphaImage else { return nil }
        let s = contentsScale
        let container = CALayer()
        container.frame = CGRect(x: Metrics.inset + crop.minX / s,
                                 y: blockBottom(block) + (CGFloat(alphaImage.height) - crop.maxY) / s,
                                 width: crop.width / s, height: crop.height / s)
        container.shadowRadius = block.fontSize * LyricEmphasis.Metrics.glowRadiusEm
        container.shadowOffset = .zero
        container.shadowOpacity = 0
        if let outline {
            // Path shadow: drawn from the outline, never from the masked content (no offscreen pass).
            let move = CGAffineTransform(translationX: -crop.minX / s, y: -(CGFloat(alphaImage.height) - crop.maxY) / s)
            container.shadowPath = outline.copy(using: [move])
        }
        let dim = CALayer()
        dim.contentsScale = s
        dim.contents = dimImage.cropping(to: crop)
        dim.frame = container.bounds
        let fill = CALayer()
        fill.frame = container.bounds
        let bright = CALayer()
        bright.frame = container.bounds
        let alpha = CALayer()
        alpha.contentsScale = s
        alpha.contents = alphaImage.cropping(to: crop)
        alpha.frame = container.bounds
        bright.mask = alpha
        fill.addSublayer(bright)
        container.addSublayer(dim)
        container.addSublayer(fill)
        paint(bright: bright, container: container, fillColor: fillColor)
        return Plates(container: container, dim: dim, fill: fill, bright: bright)
    }

    // MARK: HDR

    /// Color of the filled part: HDR level on the active line, plain active color elsewhere.
    var fillColor: CGColor {
        if state == .active, let hdrBase { return hdrBase }
        return activeSDR
    }

    /// Dark (and HDR) 0.8; light 0.3 so the dark smear stays clean.
    var maxGlow: Float {
        isDarkAppearance || hdrPeak != nil ? LyricEmphasis.Metrics.maxGlowDark : LyricEmphasis.Metrics.maxGlowLight
    }

    func paint(bright: CALayer, container: CALayer, fillColor: CGColor) {
        let hdr = state == .active && hdrBase != nil
        bright.preferredDynamicRange = hdr ? .constrainedHigh : .standard
        bright.backgroundColor = fillColor
        container.shadowColor = hdrPeak ?? activeSDR
    }

    /// Standard mode; see `setDynamicRange(headroom:mode:)`.
    func setDynamicRange(headroom: CGFloat?) { setDynamicRange(headroom: headroom, mode: .standard) }

    /// Colors only, no bitmap work (a mode change recolors too). `headroom` nil = SDR (light, no EDR
    /// screen, color creation failed); otherwise it is the largest brightness target of `mode`
    /// (`mode.peakMax`) already capped by the screen's potential.
    func setDynamicRange(headroom: CGFloat?, mode: LyricHDR.Mode) {
        var base: CGColor?, peak: CGColor?
        var baseValue: CGFloat = 1, peakValue: CGFloat = 1
        if let h = headroom, h > 1, h.isFinite {
            baseValue = LyricHDR.baseValue(headroom: h, mode: mode)
            peakValue = min(mode.peakMax, h)
            base = LyricHDR.color(white: baseValue, headroom: peakValue)
            peak = LyricHDR.color(white: peakValue, headroom: peakValue)
            if base == nil || peak == nil { base = nil; peak = nil }
        }
        let changed = (base == nil) != (hdrBase == nil) || baseValue != hdrBaseValue || peakValue != hdrPeakValue || mode != hdrMode
        hdrBase = base; hdrPeak = peak; hdrBaseValue = baseValue; hdrPeakValue = peakValue; hdrMode = mode
        guard changed, isLoaded else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyColors()
        for f in fillsFragments { f.lastMultiplier = 0; f.glyphs.forEach { $0.lastMultiplier = 0; $0.lastGlow = -1 } }
        CATransaction.commit()
        if state == .active { setPosition(lastPosition, animated: false) }
    }

    func applyColors() {
        let color = fillColor
        for f in fillsFragments {
            f.lastMultiplier = 0
            f.glyphs.forEach { $0.lastMultiplier = 0 }
            if let bright = f.bright, let container = f.container { paint(bright: bright, container: container, fillColor: color) }
            for g in f.glyphs { paint(bright: g.bright, container: g.container, fillColor: color) }
        }
    }

    // MARK: Group effects (glow, Reduce Motion brightness)

    /// Per group: glow follows the group fill ratio g (v8), fallback word pieces get their span's
    /// brightness. Glyph brightness and motion are written in `updateGlyphs`, which runs first and
    /// leaves each glyph's coverage for g.
    func updateGroupEffects(_ block: Block, t: TimeInterval) {
        for gs in block.groups {
            let g = gs.group
            let sinceEnd = t - g.end
            var parts: [(coverage: CGFloat, width: CGFloat)] = []
            // Group glyph order (v9): a fallback piece is one glyph; coverage now and at the group end.
            var now: [CGFloat] = [], atEnd: [CGFloat] = []
            for f in gs.fragments {
                if !f.glyphs.isEmpty {
                    for glyph in f.glyphs {
                        parts.append((glyph.coverage, glyph.spec.rect.width))
                        now.append(glyph.coverage); atEnd.append(glyph.endCoverage)
                    }
                    continue
                }
                let word = block.words[f.wordIndex]
                let p = LyricsLayout.wordProgress(t: t, word: word)
                parts.append((p, f.rect.width))
                now.append(p); atEnd.append(LyricsLayout.wordProgress(t: g.end, word: word))
                guard hdrBase != nil, state == .active, let bright = f.bright else { continue }
                let k = LyricEmphasis.level(coverage: p, endCoverage: LyricsLayout.wordProgress(t: g.end, word: word),
                                            sinceEnd: sinceEnd, settle: settleTime)
                let m = LyricHDR.level(progress: k, strength: g.strength, headroom: hdrPeakValue, mode: hdrMode)
                if m != f.lastMultiplier {
                    f.lastMultiplier = m
                    if let c = LyricHDR.color(white: m, headroom: hdrPeakValue) { bright.backgroundColor = c }
                }
            }
            let held = g.isHeld
            let fillNow = LyricEmphasis.groupFill(parts)
            // Held group (v2): one rise a(t) from the group start drives motion, brightness and glow.
            let rise = LyricEmphasis.heldRise(t: t, groupBegin: g.begin, groupEnd: g.end)
            let riseEnd = LyricEmphasis.heldRise(t: g.end, groupBegin: g.begin, groupEnd: g.end)
            if !gs.glyphs.isEmpty {
                applyMotion(gs, now: now, atEnd: atEnd, t: t, heldRise: held ? (rise, riseEnd) : nil)
                if held, hdrBase != nil, state == .active {
                    for glyph in gs.glyphs { updateBrightness(glyph, t: t, eased: (rise, riseEnd)) }
                }
            }
            var glow: Float = 0
            if Metrics.glowEnabled {
                if held {
                    glow = motionReduced
                        ? LyricEmphasis.reducedGlow(eased: rise, sinceEnd: sinceEnd, strength: g.strength)
                        : LyricEmphasis.glow(eased: rise, sinceEnd: sinceEnd, strength: g.strength, maxGlow: maxGlow)
                } else {
                    glow = motionReduced
                        ? LyricEmphasis.reducedGlow(fill: fillNow, sinceEnd: sinceEnd, strength: g.strength)
                        : LyricEmphasis.glow(fill: fillNow, sinceEnd: sinceEnd, strength: g.strength, maxGlow: maxGlow)
                }
            }
            if glow != gs.lastGlow {
                gs.lastGlow = glow
                for glyph in gs.glyphs { glyph.container.shadowOpacity = glow }
                for f in gs.fragments where f.glyphs.isEmpty { f.lastGlow = glow; f.container?.shadowOpacity = glow }
            }
        }
    }

    /// Lift and scale of the group's glyphs from the neighbor-weighted progress r_i (v9). `now`/`atEnd`
    /// hold every glyph slot of the group (fallback pieces included) in order; only real glyphs move.
    private func applyMotion(_ gs: GroupState, now: [CGFloat], atEnd: [CGFloat], t: TimeInterval,
                             heldRise: (now: CGFloat, end: CGFloat)? = nil) {
        let r: [CGFloat], rEnd: [CGFloat]
        if let h = heldRise {
            r = LyricEmphasis.heldInfluence(count: now.count, rise: h.now)
            rEnd = LyricEmphasis.heldInfluence(count: atEnd.count, rise: h.end)
        } else {
            r = LyricEmphasis.influence(coverages: now); rEnd = LyricEmphasis.influence(coverages: atEnd)
        }
        var slot = 0
        for f in gs.fragments {
            guard !f.glyphs.isEmpty else { slot += 1; continue }
            for g in f.glyphs {
                defer { slot += 1 }
                guard slot < r.count else { continue }
                let m = LyricEmphasis.glyphMotion(t: t, groupEnd: g.group.end, influence: r[slot],
                                                  endInfluence: rEnd[slot], strength: g.group.strength)
                guard g.lastMotion?.lift != m.lift || g.lastMotion?.scale != m.scale else { continue }
                g.lastMotion = m
                var xf = CATransform3DMakeScale(m.scale, m.scale, 1)
                xf.m42 = m.lift + (m.scale - 1) * g.container.bounds.height / 2    // scale about the bottom center
                g.container.transform = xf
            }
        }
    }

    /// Time the brightness takes to return to base after the group ended.
    private var settleTime: TimeInterval {
        motionReduced ? LyricEmphasis.Metrics.reducedFade : LyricEmphasis.Metrics.settleDuration
    }

    // MARK: Fill mask

    /// Gradient mask: opaque up to the fill `front`, then a soft `edge` fade. Shared by words and glyphs.
    func updateMask(_ fill: CALayer, front: CGFloat, edge: CGFloat, width: CGFloat) {
        if front <= 0 { fill.isHidden = true; fill.mask = nil; return }
        fill.isHidden = false
        if front - edge >= width - 0.01 { fill.mask = nil; return }
        let w = max(width, 1)
        let g = (fill.mask as? CAGradientLayer) ?? {
            let g = CAGradientLayer()
            g.startPoint = CGPoint(x: 0, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 0.5)
            let white = CGColor(gray: 1, alpha: 1), clear = CGColor(gray: 1, alpha: 0)
            g.colors = [white, white, clear, clear]
            g.frame = fill.bounds
            fill.mask = g
            return g
        }()
        let a = min(max((front - edge) / w, 0), 1), b = min(max(front / w, 0), 1)
        g.locations = [0, NSNumber(value: Double(a)), NSNumber(value: Double(b)), 1]
    }

    // MARK: Glyph wave

    /// Replaces the word pieces of emphasized words by glyph pieces. Once per activation.
    func buildGlyphs() {
        let s = contentsScale
        for block in blocks where block.fills && block.isMain {
            for gs in block.groups {
              for f in gs.fragments where !f.glyphSpecs.isEmpty {
                guard let wordContainer = f.container else { continue }
                let edges = f.glyphSpecs.map(\.rect.minX) + [f.glyphSpecs.last!.rect.maxX]
                let spans = LyricEmphasis.pixelSpans(edges: edges, scale: s)
                let maxX = Int(f.crop.maxX)
                for (spec, span) in zip(f.glyphSpecs, spans) {
                    let x0 = max(span.lowerBound, Int(f.crop.minX)), x1 = min(span.upperBound, maxX)
                    guard x1 > x0 else { continue }
                    let crop = CGRect(x: CGFloat(x0), y: f.crop.minY, width: CGFloat(x1 - x0), height: f.crop.height)
                    guard let p = makePlates(block: block, crop: crop, outline: spec.outline) else { continue }
                    p.fill.isHidden = true
                    addSublayer(p.container)
                    let glyph = Glyph(spec: spec, container: p.container, fill: p.fill, bright: p.bright, group: gs.group)
                    let word = block.words[f.wordIndex]
                    let duration = word.end - word.begin
                    let edge = block.fontSize * LyricEmphasis.edgeEm(duration: duration)
                    let endFront = LyricsLayout.wordProgress(t: gs.group.end, word: word) * (f.wordWidth + edge)
                    glyph.endCoverage = LyricEmphasis.coverage(front: endFront, left: spec.offset, width: spec.rect.width, edge: edge)
                    f.glyphs.append(glyph)
                    gs.glyphs.append(glyph)
                }
                if !f.glyphs.isEmpty { wordContainer.isHidden = true }
                f.lastProgress = -1
              }
            }
        }
    }

    /// Back to word pieces (line left `.active`, or unload).
    func removeGlyphs(_ f: Fragment) {
        guard !f.glyphs.isEmpty else { return }
        f.glyphs.forEach { $0.container.removeFromSuperlayer() }
        f.glyphs = []
    }

    /// Per-frame glyph update: mask locations, coverage and HDR level (the transform is set per group in `applyMotion`), each written only when it changed.
    /// Coverage comes from the same `front` as the mask, so the wave, the fill and the glow share one boundary.
    func updateGlyphs(_ f: Fragment, word: LyricWord, t: TimeInterval, progress p: CGFloat, edge: CGFloat) {
        let front = p * (f.wordWidth + edge)
        let moved = p != f.lastProgress
        f.lastProgress = p
        for g in f.glyphs {
            if moved { updateMask(g.fill, front: front - g.spec.offset, edge: edge, width: g.spec.rect.width) }
            g.coverage = LyricEmphasis.coverage(front: front, left: g.spec.offset, width: g.spec.rect.width, edge: edge)
            if hdrBase != nil, state == .active, !g.group.isHeld { updateBrightness(g, t: t) }
        }
    }

    /// Base at rest up to the group's peak with e(coverage); quantized so settled glyphs stop touching the color.
    private func updateBrightness(_ g: Glyph, t: TimeInterval, eased: (now: CGFloat, end: CGFloat)? = nil) {
        let k: CGFloat
        if let a = eased {
            k = LyricEmphasis.level(eased: a.now, endEased: a.end, sinceEnd: t - g.group.end, settle: settleTime)
        } else {
            k = LyricEmphasis.level(coverage: g.coverage, endCoverage: g.endCoverage, sinceEnd: t - g.group.end, settle: settleTime)
        }
        let m = LyricHDR.level(progress: k, strength: g.group.strength, headroom: hdrPeakValue, mode: hdrMode)
        guard m != g.lastMultiplier else { return }
        g.lastMultiplier = m
        if let c = LyricHDR.color(white: m, headroom: hdrPeakValue) { g.bright.backgroundColor = c }
    }
}
