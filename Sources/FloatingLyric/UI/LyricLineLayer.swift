import AppKit
import QuartzCore
import CoreText

/// One lyric line (PLAN 4.1). Text is laid out once with Core Text and rendered into
/// two bitmaps: the unfilled text and a white alpha plate. Per fragment a solid-color
/// `bright` layer, masked by the plate, is revealed through a gradient mask on its `fill`
/// parent, so per-frame work is only mask geometry; text is never laid out again.
/// The solid color is what makes the HDR highlight possible (`LyricLineLayer+Emphasis`).
///
/// Bitmaps are created lazily (`loadContent`) so a long song does not hold a
/// bitmap per line in memory (budget: +30 MB).
final class LyricLineLayer: CALayer {
    enum State { case past, active, upcoming }

    enum Metrics {
        /// Transparent border so the blur filter does not clip glyph edges.
        static let inset: CGFloat = 8
        static let liftDistance: CGFloat = 1.5
        static let liftDuration: CFTimeInterval = 0.35
        static let backgroundScale: CGFloat = 0.7
        static let translationScale: CGFloat = 0.6
        static let blockGapEm: CGFloat = 0.15
        static let lineFadeDuration: CFTimeInterval = 0.25
        /// Glow of emphasized words (PLAN 4.1 v4); set `glowEnabled` false to switch off.
        static let glowEnabled = true
        static let fragmentPad: CGFloat = 1
    }

    /// Text height (without the blur inset); the list lays rows out with this.
    private(set) var height: CGFloat = 0
    let line: LyricLine
    let timing: LyricsDocument.Timing
    let textWidth: CGFloat
    let isRightAligned: Bool
    private(set) var state: State = .upcoming
    /// Reduce Motion: no lift, no glyph wave; emphasized words get a fixed glow.
    var motionReduced = false
    private(set) var isLoaded = false

    final class Fragment {
        let wordIndex: Int
        let rect: CGRect           // block space, bottom-left origin
        /// Start of this piece within the word's text (a wrapped word has several pieces) and the word's total width.
        var wordOffset: CGFloat = 0
        var wordWidth: CGFloat = 0
        /// Glyph pieces for emphasis; empty when the word is not emphasized or could not be split.
        var glyphSpecs: [GlyphSpec] = []
        /// Index into `Block.groups` when the word belongs to an emphasized group.
        var groupIndex: Int?
        var lastMultiplier: CGFloat = 0
        var wordGlyphCount = 1
        var glyphs: [Glyph] = []
        var crop: CGRect = .zero
        /// Word-piece outline (block space) for the glow of emphasized groups; nil for plain words.
        var outline: CGPath?   // pixel crop in the block bitmaps
        var container: CALayer?
        var dim: CALayer?
        var fill: CALayer?
        var bright: CALayer?
        var lastProgress: CGFloat = -1
        var lastGlow: Float = -1
        var lifted = false
        init(wordIndex: Int, rect: CGRect) { self.wordIndex = wordIndex; self.rect = rect }
    }

    final class Block {
        let words: [LyricWord]
        let fontSize: CGFloat
        let fills: Bool            // false = static text (translation)
        let isMain: Bool           // main vocal; only this block is emphasized
        var top: CGFloat = 0       // offset from the top of the line
        var size: CGSize = .zero
        var frame: CTFrame?
        var fragments: [Fragment] = []
        var groups: [GroupState] = []
        var dimImage: CGImage?
        var alphaImage: CGImage?
        var staticLayer: CALayer?
        init(words: [LyricWord], fontSize: CGFloat, fills: Bool, isMain: Bool = false) {
            self.words = words; self.fontSize = fontSize; self.fills = fills; self.isMain = isMain
        }
    }

    var blocks: [Block] = []
    private var palette: LyricPalette
    private var appearance: NSAppearance
    var lastPosition: TimeInterval = 0

    // Active color and HDR state (see `LyricLineLayer+Emphasis`).
    var activeSDR: CGColor = CGColor(gray: 1, alpha: 1)
    var hdrBase: CGColor?
    /// Resolved at `loadContent`; picks the glow strength.
    var isDarkAppearance = false
    var hdrPeak: CGColor?
    var hdrMode: LyricHDR.Mode = .standard
    var hdrBaseValue: CGFloat = 1
    /// Cap of the peak colors (headroom, at most the mode's peakMax); each group peaks lower by its strength.
    var hdrPeakValue: CGFloat = 1

    /// - Parameters:
    ///   - width: text width in points (the layer itself is `width + 2 * inset` wide)
    init(line: LyricLine, timing: LyricsDocument.Timing, width: CGFloat, fontSize: CGFloat,
         rightAligned: Bool, translation: String?, palette: LyricPalette, appearance: NSAppearance) {
        self.line = line
        self.timing = timing
        self.textWidth = max(width, 1)
        self.isRightAligned = rightAligned
        self.palette = palette
        self.appearance = appearance
        super.init()
        layoutBlocks(fontSize: fontSize, translation: translation)
        let inset = Metrics.inset
        bounds = CGRect(x: 0, y: 0, width: textWidth + 2 * inset, height: height + 2 * inset)
        anchorPoint = CGPoint(x: rightAligned ? (bounds.width - inset) / bounds.width : inset / bounds.width, y: 0.5)
    }

    override init(layer: Any) {
        // Presentation copies; never used for layout.
        let other = layer as! LyricLineLayer
        line = other.line; timing = other.timing; textWidth = other.textWidth
        isRightAligned = other.isRightAligned; palette = other.palette; appearance = other.appearance
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Layout (once per width / font change)

    private func layoutBlocks(fontSize: CGFloat, translation: String?) {
        var specs: [Block] = [Block(words: line.words, fontSize: fontSize, fills: true, isMain: true)]
        if !line.background.isEmpty {
            specs.append(Block(words: line.background, fontSize: fontSize * Metrics.backgroundScale, fills: true))
        }
        if let translation, !translation.isEmpty {
            let w = LyricWord(text: translation, begin: 0, end: 0, trailingSpace: false)
            specs.append(Block(words: [w], fontSize: fontSize * Metrics.translationScale, fills: false))
        }
        var y: CGFloat = 0
        for block in specs {
            layout(block)
            guard block.size.height > 0 else { continue }
            block.top = y
            y += block.size.height + fontSize * Metrics.blockGapEm
            blocks.append(block)
        }
        height = max(y - fontSize * Metrics.blockGapEm, 0).rounded(.up)
    }

    private func layout(_ block: Block) {
        let weight: NSFont.Weight = block.fills ? .bold : .medium
        let font = NSFont.systemFont(ofSize: block.fontSize, weight: weight)
        let para = NSMutableParagraphStyle()
        para.alignment = isRightAligned ? .right : .left
        para.lineBreakMode = .byWordWrapping

        var text = ""
        var ranges: [NSRange] = []
        for (i, w) in block.words.enumerated() {
            let loc = text.utf16.count
            text += w.text
            ranges.append(NSRange(location: loc, length: w.text.utf16.count))
            if w.trailingSpace && i < block.words.count - 1 { text += " " }
        }
        guard !text.isEmpty else { return }
        // Without this flag Core Text paints black and ignores the context's fill color.
        let fromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .paragraphStyle: para, fromContext: true])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: textWidth, height: .greatestFiniteMagnitude), nil)
        let size = CGSize(width: textWidth, height: ceil(fit.height))
        let frame = CTFramesetterCreateFrame(
            setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), nil)
        block.size = size
        block.frame = frame
        guard block.fills else { return }

        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let pad = Metrics.fragmentPad
        let bounds = CGRect(origin: .zero, size: size)
        var groupOfWord = [Int?](repeating: nil, count: ranges.count)
        if block.isMain, timing == .word {
            block.groups = LyricEmphasis.groups(words: block.words).map { GroupState($0) }
            for (gi, g) in block.groups.enumerated() { for wi in g.group.range { groupOfWord[wi] = gi } }
        }
        var consumed = [CGFloat](repeating: 0, count: ranges.count)
        var glyphCount = [Int](repeating: 0, count: ranges.count)
        for (li, ctLine) in lines.enumerated() {
            let lr = CTLineGetStringRange(ctLine)
            let lineRange = NSRange(location: lr.location, length: lr.length)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil)
            for (wi, wr) in ranges.enumerated() where wr.length > 0 {
                let part = NSIntersectionRange(wr, lineRange)
                guard part.length > 0 else { continue }
                let x1 = CTLineGetOffsetForStringIndex(ctLine, part.location, nil)
                let x2 = CTLineGetOffsetForStringIndex(ctLine, part.location + part.length, nil)
                let r = CGRect(x: origins[li].x + min(x1, x2), y: origins[li].y - descent - pad,
                               width: abs(x2 - x1), height: ascent + descent + 2 * pad)
                let clipped = r.intersection(bounds)
                guard !clipped.isNull && clipped.width > 0 else { continue }
                let frag = Fragment(wordIndex: wi, rect: clipped)
                frag.wordOffset = consumed[wi]
                consumed[wi] += clipped.width
                if let gi = groupOfWord[wi] {
                    frag.groupIndex = gi
                    block.groups[gi].fragments.append(frag)
                    frag.glyphSpecs = glyphSpecs(text: text as NSString, part: part, line: ctLine,
                                                 origin: origins[li], rect: clipped, wordOffset: frag.wordOffset)
                    frag.outline = Self.outline(line: ctLine, origin: origins[li], range: part)
                    glyphCount[wi] += frag.glyphSpecs.count
                }
                block.fragments.append(frag)
            }
        }
        for f in block.fragments {
            f.wordWidth = consumed[f.wordIndex]
            f.wordGlyphCount = max(glyphCount[f.wordIndex], 1)
        }
    }

    // MARK: Bitmaps (lazy)

    /// `color` is white for the alpha plate that the HDR-capable `bright` layers are masked with.
    private func renderImage(_ block: Block, color: CGColor) -> CGImage? {
        guard let frame = block.frame else { return nil }
        let s = contentsScale
        let w = max(Int(ceil(block.size.width * s)), 1), h = max(Int(ceil(block.size.height * s)), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: s, y: s)
        ctx.setFillColor(color)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }

    /// Renders the bitmaps and builds the per-word layers. Call when the line gets near the viewport.
    func loadContent() {
        guard !isLoaded else { return }
        isLoaded = true
        activeSDR = LyricPalette.resolve(palette.active, in: appearance)
        isDarkAppearance = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let unfilled = LyricPalette.resolve(palette.unfilled, in: appearance)
        let secondary = LyricPalette.resolve(palette.secondary, in: appearance)
        let s = contentsScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for block in blocks {
            if !block.fills {
                guard let img = renderImage(block, color: secondary) else { continue }
                let layer = CALayer()
                layer.contentsScale = s
                layer.contents = img
                layer.frame = CGRect(x: Metrics.inset, y: blockBottom(block), width: block.size.width, height: block.size.height)
                addSublayer(layer)
                block.staticLayer = layer
                continue
            }
            block.dimImage = renderImage(block, color: unfilled)
            block.alphaImage = renderImage(block, color: CGColor(gray: 1, alpha: 1))
            guard let alphaImage = block.alphaImage else { continue }
            for frag in block.fragments {
                // Whole-pixel crop so the pieces tile the bitmap exactly.
                let px0 = max(Int(floor(frag.rect.minX * s)), 0)
                let px1 = min(Int(ceil(frag.rect.maxX * s)), alphaImage.width)
                let py0 = max(Int(floor((block.size.height - frag.rect.maxY) * s)), 0)
                let py1 = min(Int(ceil((block.size.height - frag.rect.minY) * s)), alphaImage.height)
                guard px1 > px0, py1 > py0 else { continue }
                frag.crop = CGRect(x: px0, y: py0, width: px1 - px0, height: py1 - py0)
                guard let plates = makePlates(block: block, crop: frag.crop, outline: frag.outline) else { continue }
                addSublayer(plates.container)
                frag.container = plates.container
                frag.dim = plates.dim
                frag.fill = plates.fill
                frag.bright = plates.bright
                frag.lastProgress = -1
                frag.lifted = false
            }
        }
        CATransaction.commit()
        applyStateAppearance(animated: false)
        if state == .active { setPosition(lastPosition, animated: false) }
    }

    /// Drops bitmaps and sublayers when the line is far from the viewport.
    func unloadContent() {
        guard isLoaded else { return }
        isLoaded = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        for b in blocks {
            b.dimImage = nil; b.alphaImage = nil; b.staticLayer = nil
            for f in b.fragments { f.container = nil; f.dim = nil; f.fill = nil; f.bright = nil; f.glyphs = [] }
            b.groups.forEach { $0.glyphs = []; $0.lastGlow = -1 }
        }
    }

    /// Appearance or glass changed: the unfilled color is baked into its bitmap, so draw again.
    func rerender(palette: LyricPalette, appearance: NSAppearance) {
        self.palette = palette
        self.appearance = appearance
        guard isLoaded else { return }
        unloadContent()
        loadContent()
    }

    // MARK: State

    func setState(_ new: State, animated: Bool = true) {
        guard new != state else { return }
        state = new
        applyStateAppearance(animated: animated)
        if new == .active && isLoaded { setPosition(lastPosition, animated: false) }
    }

    var fillsFragments: [Fragment] { blocks.filter(\.fills).flatMap(\.fragments) }

    private func applyStateAppearance(animated: Bool) {
        guard isLoaded else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for f in fillsFragments {
            guard let container = f.container, let fill = f.fill, let dim = f.dim else { continue }
            removeGlyphs(f)
            f.lastProgress = -1
            f.lastGlow = 0
            f.lifted = false
            container.isHidden = false
            container.transform = CATransform3DIdentity
            container.shadowOpacity = 0
            f.lastMultiplier = 0
            fill.mask = nil
            fill.removeAllAnimations()
            if state == .active {
                dim.isHidden = false
                if timing == .word {
                    fill.isHidden = true      // setPosition reveals it
                } else {
                    fill.isHidden = false
                    fill.opacity = 1
                    if animated && !motionReduced {
                        let fade = CABasicAnimation(keyPath: "opacity")
                        fade.fromValue = 0
                        fade.toValue = 1
                        fade.duration = Metrics.lineFadeDuration
                        fill.add(fade, forKey: "fade")
                    }
                }
            } else {
                dim.isHidden = true
                fill.isHidden = false
            }
        }
        blocks.forEach { $0.groups.forEach { $0.glyphs = []; $0.lastGlow = -1 } }
        if state == .active && timing == .word && !motionReduced { buildGlyphs() }
        applyColors()
        CATransaction.commit()
    }

    // MARK: Per-frame

    /// Updates mask geometry, lift and glow for time `t`. Cheap; no text work.
    func setPosition(_ t: TimeInterval, animated: Bool = true) {
        lastPosition = t
        guard state == .active, isLoaded, timing == .word else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for block in blocks where block.fills {
            for f in block.fragments {
                guard let container = f.container, let fill = f.fill else { continue }
                let word = block.words[f.wordIndex]
                let duration = word.end - word.begin
                let edge = block.fontSize * LyricEmphasis.edgeEm(duration: duration)
                let p = LyricsLayout.wordProgress(t: t, word: word)
                if !f.glyphs.isEmpty {
                    updateGlyphs(f, word: word, t: t, progress: p, edge: edge)
                    continue
                }
                if p != f.lastProgress {
                    f.lastProgress = p
                    updateMask(fill, front: p * (fill.bounds.width + edge), edge: edge, width: fill.bounds.width)
                }
                let shouldLift = t >= word.begin && !motionReduced
                if shouldLift != f.lifted {
                    f.lifted = shouldLift
                    let y = shouldLift ? Metrics.liftDistance : 0
                    if animated {
                        let a = CABasicAnimation(keyPath: "transform.translation.y")
                        a.fromValue = container.presentation()?.transform.m42 ?? (shouldLift ? 0 : Metrics.liftDistance)
                        a.toValue = y
                        a.duration = Metrics.liftDuration
                        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        container.add(a, forKey: "lift")
                    }
                    container.transform = CATransform3DMakeTranslation(0, y, 0)
                }
            }
            updateGroupEffects(block, t: t)
        }
        CATransaction.commit()
    }
}
