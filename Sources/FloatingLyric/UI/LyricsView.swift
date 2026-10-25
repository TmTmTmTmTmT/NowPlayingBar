import AppKit
import QuartzCore
import os

private let log = Logger(subsystem: "FloatingLyric", category: "lyrics-view")

/// What to show when there is no document.
enum LyricsEmptyState: Equatable {
    case none, loading, noLyrics
    /// Music caches lyrics only after its lyrics screen was opened once per launch (FIX_GUIDE F1).
    case openLyricsInMusicOnce

    var message: String? {
        switch self {
        case .none:                  return nil
        case .loading:               return "가사를 찾는 중…"
        case .noLyrics:              return "가사를 찾지 못했습니다"
        case .openLyricsInMusicOnce: return "Apple Music에서 가사를 한 번 열어 주세요"
        }
    }

    /// Smaller second line under `message`.
    var detail: String? {
        switch self {
        case .openLyricsInMusicOnce: return "Music을 켤 때마다 처음 한 번만 필요합니다"
        case .noLyrics:              return "Apple Music에서 이 곡의 가사를 열면 바로 표시됩니다"
        default:                     return nil
        }
    }
}

/// The scrolling lyrics list (PLAN 4.2). Layer-backed and transparent; the host puts it
/// inside the glass. Frames come from a display link that runs only while there is
/// something to animate.
final class LyricsView: NSView {
    enum Metrics {
        static let verticalPadding: CGFloat = 14
        static let defaultHorizontalPadding: CGFloat = 22
        static let spacingEm: CGFloat = 0.55
        static let userScrollResume: TimeInterval = 3
        static let edgeFadeLines: CGFloat = 0.8
        /// Never fade more than this share of the height from each edge (1-line panels).
        static let edgeFadeCap: CGFloat = 0.3
        static let staggerStep: CFTimeInterval = 0.04
        static let springResponse: CGFloat = 0.5
        static let springDamping: CGFloat = 1.0
        static let transition: CFTimeInterval = 0.25
        /// Line-to-line move (scroll, opacity, blur, scale share it).
        static let lineTransition: CFTimeInterval = 0.5
        /// The centered line / interlude switch this much before the real begin.
        static let lineLead: TimeInterval = 0.3
        static let reducedFade: CFTimeInterval = 0.2
        static let emptyFontSize: CGFloat = 13
        static let emptyDetailFontSize: CGFloat = 11
        static let emptyLineGap: CGFloat = 3
        static let cleanupDelay: TimeInterval = 0.9
        static func fontSize(_ p: LyricPreferences.Placement) -> CGFloat {
            switch p {
            case .floating:     return 17
            case .belowCard:    return 17
            case .belowMenuBar: return 14
            }
        }
    }

    // MARK: Public surface

    /// Clicking a line seeks to its `begin` (only while `LyricPreferences.clickToSeek` is on).
    var onSeek: ((TimeInterval) -> Void)?
    /// true when the user starts scrolling, false when scrolling ends or is reset.
    var onUserScrollChange: ((Bool) -> Void)?
    var placement: LyricPreferences.Placement = .floating {
        didSet { if placement != oldValue { reload() } }
    }
    /// Side inset of the text, set per placement by the panel (= its corner radius, PLAN 4.2 v3).
    var horizontalPadding: CGFloat = Metrics.defaultHorizontalPadding {
        didSet { if horizontalPadding != oldValue { reload() } }
    }
    let clock = LyricClock()

    static func fontSize(for placement: LyricPreferences.Placement,
                         textSize: LyricPreferences.TextSize) -> CGFloat {
        Metrics.fontSize(placement) * textSize.scale
    }

    static func lineHeight(fontSize: CGFloat) -> CGFloat {
        let f = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        return ceil(f.ascender - f.descender + f.leading)
    }

    /// Panel height for `lines` visible lines: N x (line height + spacing) + padding.
    static func preferredHeight(lines: Int, textSize: LyricPreferences.TextSize,
                                placement: LyricPreferences.Placement = .floating) -> CGFloat {
        let fs = fontSize(for: placement, textSize: textSize)
        return CGFloat(max(lines, 1)) * (lineHeight(fontSize: fs) + fs * Metrics.spacingEm)
            + 2 * Metrics.verticalPadding
    }

    // MARK: State

    private enum RowKind { case line(Int), interlude(before: Int) }
    private struct Row {
        var kind: RowKind
        var layer: CALayer
        var textHeight: CGFloat
        var line: LyricLineLayer? { layer as? LyricLineLayer }
        var interlude: InterludeLayer? { layer as? InterludeLayer }
    }
    /// What the list currently highlights; a change means a re-layout.
    private struct Focus: Equatable {
        var activeLine: Int?
        var playedLines: Int
        var interludeBefore: Int?
        /// Earlier lines still being sung (overlap with the active line); drawn active.
        var lingering: [Int] = []
    }

    private let preferences: LyricPreferences
    private var document: LyricsDocument?
    private var emptyState: LyricsEmptyState = .none
    private var glass = GlassAppearance.regular
    private var palette = LyricPalette(glass: .regular)
    private var renderedKey: String?

    private let rowsLayer = CALayer()
    private let fadeMask = CAGradientLayer()
    private let emptyLayer = CATextLayer()
    private let emptyDetailLayer = CATextLayer()
    private var rows: [Row] = []
    private var lineRow: [Int] = []
    private var lastStyles: [LyricsLayout.RowStyle] = []
    private var lastBlur: [CGFloat] = []
    private var focus: Focus?
    private var builtSize: CGSize = .zero
    private var currentOffset: CGFloat = 0

    private var isUserScrolling = false
    private var frozenOffset: CGFloat = 0
    private var resumeTimer: Timer?
    private var cleanupWork: DispatchWorkItem?
    /// Created on first start; never touched in `deinit` unless it exists (FIX_GUIDE F13).
    private var driver: LyricFrameDriver?
    private var occlusionObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var screenParamsObserver: NSObjectProtocol?
    /// HDR headroom for the current line's filled part; nil = SDR (PLAN 4.1 v4 B).
    private var hdrHeadroom: CGFloat?
    private var hdrMode: LyricHDR.Mode = .standard

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    private var fontSize: CGFloat { Self.fontSize(for: placement, textSize: preferences.textSize) }
    private var spacing: CGFloat { fontSize * Metrics.spacingEm }
    private var isStatic: Bool { document?.timing == LyricsDocument.Timing.none }

    // MARK: Init

    init(preferences: LyricPreferences = .shared) {
        self.preferences = preferences
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true      // lets CIGaussianBlur on line layers render
        layer?.masksToBounds = true
        layer?.addSublayer(rowsLayer)
        rowsLayer.mask = fadeMask
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        emptyLayer.alignmentMode = .center
        emptyLayer.isWrapped = true
        emptyLayer.font = NSFont.systemFont(ofSize: Metrics.emptyFontSize)
        emptyLayer.fontSize = Metrics.emptyFontSize
        emptyLayer.isHidden = true
        layer?.addSublayer(emptyLayer)
        emptyDetailLayer.alignmentMode = .center
        emptyDetailLayer.isWrapped = true
        emptyDetailLayer.font = NSFont.systemFont(ofSize: Metrics.emptyDetailFontSize)
        emptyDetailLayer.fontSize = Metrics.emptyDetailFontSize
        emptyDetailLayer.isHidden = true
        layer?.addSublayer(emptyDetailLayer)
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateDynamicRange() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        resumeTimer?.invalidate()
        driver?.stop()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let screenParamsObserver { NotificationCenter.default.removeObserver(screenParamsObserver) }
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Content

    func show(document: LyricsDocument?, emptyState: LyricsEmptyState) {
        let usable = document.flatMap { $0.lines.isEmpty ? nil : $0 }
        self.document = usable
        clock.resetDisplayedPosition()      // new track or document: start from its real position
        self.emptyState = usable == nil ? (emptyState == .none && document != nil ? .noLyrics : emptyState) : .none
        endUserScroll()
        if let usable {
            log.debug("show lines=\(usable.lines.count, privacy: .public) timing=\(String(describing: usable.timing), privacy: .public)")
        }
        rebuildRows()
        updateEmptyLayer()
        updateDriver()
        if usable != nil { tick(jump: true) }
    }

    func update(timeline: PlaybackTimeline) {
        let jumped = clock.update(timeline: timeline, now: Date())
        updateDriver()
        if document != nil { tick(jump: jumped) }
    }

    func apply(glass: GlassAppearance) {
        guard glass != self.glass else { return }
        self.glass = glass
        palette = LyricPalette(glass: glass)
        appearance = glass.pinnedDark.flatMap { NSAppearance(named: $0 ? .darkAqua : .aqua) }
        updateDynamicRange()
        rerenderIfNeeded()
    }

    /// Re-decides HDR from appearance and screen, then recolors the lines (no bitmap work).
    /// HDR needs a Dark look (pinned-dark clear glass counts), an EDR-capable screen and a headroom color.
    func updateDynamicRange() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let potential = window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        let mode = Self.hdrMode(for: glass)
        var headroom = LyricHDR.headroom(isDark: dark, potential: potential, target: mode.peakMax)
        if let h = headroom, LyricHDR.color(white: h, headroom: h) == nil { headroom = nil }
        hdrHeadroom = headroom
        hdrMode = mode
        rows.forEach { $0.line?.setDynamicRange(headroom: headroom, mode: mode) }
    }

    /// Clear glass gets stronger HDR targets: no blur = plainClear, blur = clearFrost (PLAN 12.27).
    static func hdrMode(for glass: GlassAppearance) -> LyricHDR.Mode {
        guard glass.isClear else { return .standard }
        return glass.blurHidden ? .plainClear : .clearFrost
    }

    /// Preferences changed (context, lines, size, blur, translation).
    func reload() {
        rebuildRows()
        updateEmptyLayer()
        if document != nil { tick(jump: true) }
    }

    // MARK: Rows

    private func rebuildRows() {
        rows.forEach { $0.layer.removeFromSuperlayer() }
        rows = []; lineRow = []; lastStyles = []; lastBlur = []; focus = nil
        builtSize = bounds.size
        guard let doc = document, bounds.width > 0 else { return }
        let textWidth = max(bounds.width - 2 * horizontalPadding, 40)
        let interludes = doc.timing == .none ? Set<Int>() : LyricsLayout.interludeLines(lines: doc.lines)
        let firstAgent = doc.lines.first?.agent
        let showTranslation = preferences.showTranslation
        let appearance = effectiveAppearance
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, line) in doc.lines.enumerated() {
            if interludes.contains(i) {
                let layer = InterludeLayer(fontSize: fontSize, width: textWidth, palette: palette, appearance: appearance)
                layer.contentsScale = scale
                layer.opacity = 0
                rowsLayer.addSublayer(layer)
                rows.append(Row(kind: .interlude(before: i), layer: layer, textHeight: layer.height))
            }
            let right = line.agent != nil && line.agent != firstAgent
            let layer = LyricLineLayer(line: line, timing: doc.timing, width: textWidth, fontSize: fontSize,
                                       rightAligned: right, translation: showTranslation ? line.translation : nil,
                                       palette: palette, appearance: appearance)
            layer.contentsScale = scale
            layer.motionReduced = reduceMotion
            layer.setDynamicRange(headroom: hdrHeadroom, mode: hdrMode)
            layer.isHidden = true
            rowsLayer.addSublayer(layer)
            lineRow.append(rows.count)
            rows.append(Row(kind: .line(i), layer: layer, textHeight: layer.height))
        }
        CATransaction.commit()
        lastStyles = rows.map { _ in LyricsLayout.RowStyle(y: 0, opacity: 0, blurRadius: 0, scale: 1, isVisible: false) }
        lastBlur = rows.map { _ in 0 }
        currentOffset = -Metrics.verticalPadding
        frozenOffset = currentOffset
    }

    private func updateEmptyLayer() {
        let msg = emptyState.message
        let detail = emptyState.detail
        let hidden = msg == nil || document != nil
        emptyLayer.isHidden = hidden
        emptyDetailLayer.isHidden = hidden || detail == nil
        emptyLayer.string = msg
        emptyDetailLayer.string = detail
        emptyLayer.contentsScale = scale
        emptyDetailLayer.contentsScale = scale
        emptyLayer.foregroundColor = LyricPalette.resolve(palette.secondary, in: effectiveAppearance)
        emptyDetailLayer.foregroundColor = LyricPalette.resolve(palette.secondary, in: effectiveAppearance)
        let h = ceil(Metrics.emptyFontSize * 1.3)
        let dh = ceil(Metrics.emptyDetailFontSize * 1.3)
        let total = detail == nil ? h : h + Metrics.emptyLineGap + dh
        let width = max(bounds.width - 2 * horizontalPadding, 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let top = (bounds.height + total) / 2          // layer coordinates grow upward
        emptyLayer.frame = CGRect(x: horizontalPadding, y: top - h, width: width, height: h)
        emptyDetailLayer.frame = CGRect(x: horizontalPadding, y: top - total, width: width, height: dh)
        CATransaction.commit()
    }

    private func rerenderIfNeeded() {
        let key = "\(palette.active.hashValue)|\(palette.unfilled.hashValue)|\(effectiveAppearance.name.rawValue)|\(scale)"
        guard key != renderedKey else { return }
        renderedKey = key
        let appearance = effectiveAppearance
        rows.forEach {
            $0.line?.rerender(palette: palette, appearance: appearance)
            $0.interlude?.rerender(palette: palette, appearance: appearance)
        }
        updateEmptyLayer()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDynamicRange()
        rerenderIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rows.forEach { $0.layer.contentsScale = scale }
        rerenderIfNeeded()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rowsLayer.frame = bounds
        fadeMask.frame = bounds
        updateFadeMask()
        CATransaction.commit()
        updateEmptyLayer()
        if abs(bounds.width - builtSize.width) > 0.5 {
            rebuildRows()
            if document != nil { tick(jump: true) }
        } else if abs(bounds.height - builtSize.height) > 0.5 {
            builtSize = bounds.size
            applyLayout(animated: false)
        }
    }

    private func updateFadeMask() {
        guard bounds.height > 0 else { return }
        let fade = min(LyricsView.lineHeight(fontSize: fontSize) * Metrics.edgeFadeLines,
                       bounds.height * Metrics.edgeFadeCap)
        let f = NSNumber(value: Double(fade / bounds.height))
        let white = CGColor(gray: 1, alpha: 1), clear = CGColor(gray: 1, alpha: 0)
        fadeMask.colors = [clear, white, white, clear]
        fadeMask.locations = [0, f, NSNumber(value: 1 - f.doubleValue), 1]
    }

    // MARK: Frame driver

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let window {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
            ) { [weak self] _ in self?.updateDynamicRange() }
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.updateDriver() }
            rows.forEach { $0.layer.contentsScale = scale }
            updateDynamicRange()
            rerenderIfNeeded()
        } else {
            resumeTimer?.invalidate()
            resumeTimer = nil
        }
        updateDriver()
    }

    override func viewDidHide() { super.viewDidHide(); updateDriver() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateDriver() }

    /// The link runs only when something is visibly moving (GUIDELINES 5).
    private func updateDriver() {
        let needed = window != nil && !isHiddenOrHasHiddenAncestor
            && (window?.occlusionState.contains(.visible) ?? false)
            && document != nil && !isStatic && clock.isRunning
        if needed {
            let d = driver ?? LyricFrameDriver { [weak self] in self?.tick(jump: false) }
            driver = d
            d.start(on: self)
        } else {
            driver?.stop()
        }
    }

    /// Test hook: whether a display link is currently active.
    var isDriverRunning: Bool { driver?.isRunning ?? false }

    // MARK: Per frame

    private func currentFocus(at t: TimeInterval, doc: LyricsDocument) -> (Focus, Double) {
        if isStatic { return (Focus(activeLine: nil, playedLines: 0, interludeBefore: nil), 0) }
        let r = LyricsLayout.focus(at: t, lead: Metrics.lineLead, lines: doc.lines)
        if let before = r.interludeBefore {
            return (Focus(activeLine: nil, playedLines: before, interludeBefore: before, lingering: r.lingering), r.progress)
        }
        return (Focus(activeLine: r.activeLine, playedLines: (r.activeLine ?? -1) + 1, interludeBefore: nil,
                      lingering: r.lingering), 0)
    }

    private func tick(jump: Bool) {
        guard let doc = document, !rows.isEmpty else { return }
        let t = clock.position(at: Date())
        let (newFocus, progress) = currentFocus(at: t, doc: doc)
        if newFocus != focus || jump {
            // Lines that just stopped lingering get their last glyph filled once.
            if let old = focus, !jump {
                for i in old.lingering where !newFocus.lingering.contains(i) && i < doc.lines.count {
                    rows[lineRow[i]].line?.setPosition(LyricsLayout.sungEnd(of: doc.lines[i]), animated: false)
                }
            }
            focus = newFocus
            applyStates(newFocus, animated: !jump)
            applyLayout(animated: !jump && !isUserScrolling, lineTransition: true)
            if jump && !reduceMotion { fadeRows(duration: Metrics.transition) }
        }
        for i in newFocus.lingering { rows[lineRow[i]].line?.setPosition(t, animated: !jump) }
        if let idx = newFocus.activeLine { rows[lineRow[idx]].line?.setPosition(t, animated: !jump) }
        if let before = newFocus.interludeBefore, let row = rows.first(where: {
            if case .interlude(let b) = $0.kind { return b == before } else { return false } }) {
            row.interlude?.setProgress(CGFloat(progress))
        }
    }

    private func fadeRows(duration: CFTimeInterval) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.duration = duration
        rowsLayer.add(a, forKey: "jumpFade")
    }

    private func applyStates(_ f: Focus, animated: Bool) {
        for row in rows {
            switch row.kind {
            case .line(let i):
                let s: LyricLineLayer.State = (i == f.activeLine || f.lingering.contains(i)) ? .active : (i < f.playedLines ? .past : .upcoming)
                row.line?.motionReduced = reduceMotion
                row.line?.setState(s, animated: animated)
            case .interlude(let before):
                row.interlude?.setBreathing(before == f.interludeBefore && !reduceMotion)
            }
        }
    }

    // MARK: Layout

    private func activeRowIndex() -> Int {
        guard let f = focus else { return 0 }
        if let before = f.interludeBefore,
           let r = rows.firstIndex(where: { if case .interlude(let b) = $0.kind { return b == before } else { return false } }) {
            return r
        }
        return lineRow[min(max(f.activeLine ?? 0, 0), max(lineRow.count - 1, 0))]
    }

    private func layoutInput(heights: [CGFloat], activeRow: Int) -> LyricsLayout.Input {
        LyricsLayout.Input(
            heights: heights, activeRow: activeRow, context: preferences.context,
            visibleLines: preferences.lines, spacing: spacing,
            viewportHeight: bounds.height, topPadding: Metrics.verticalPadding, bottomPadding: Metrics.verticalPadding,
            blurInactive: preferences.blurInactive, isUserScrolling: isUserScrolling,
            offsetOverride: (isUserScrolling || isStatic) ? frozenOffset : nil,
            visibilityMargin: LyricsView.lineHeight(fontSize: fontSize))
    }

    private func rowHeights() -> [CGFloat] {
        rows.map { row in
            if case .interlude(let b) = row.kind { return b == focus?.interludeBefore ? row.textHeight : 0 }
            return row.textHeight
        }
    }

    /// Moves every row to its slot. Positions use a spring with a per-row stagger;
    /// Reduce Motion replaces that with a short fade.
    private func applyLayout(animated: Bool, lineTransition: Bool = false) {
        guard !rows.isEmpty, bounds.height > 0 else { return }
        let heights = rowHeights()
        let activeRow = activeRowIndex()
        let input = layoutInput(heights: heights, activeRow: activeRow)
        var styles = LyricsLayout.styles(input)
        if isStatic {
            styles = styles.map { var s = $0; s.opacity = 1; s.blurRadius = 0; s.scale = 1; return s }
        }
        for i in (focus?.lingering ?? []) where i < lineRow.count {
            let r = lineRow[i]
            guard r < styles.count else { continue }
            styles[r].opacity = 1; styles[r].blurRadius = 0; styles[r].scale = 1
        }
        currentOffset = input.offsetOverride ?? LyricsLayout.followOffset(input)
        let reduce = reduceMotion
        let wantBlur = preferences.blurInactive && !isUserScrolling && !isStatic

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (r, row) in rows.enumerated() {
            let s = styles[r], old = lastStyles[r]
            let isInterlude = row.interlude != nil
            let show = s.isVisible || (isInterlude && old.isVisible) || (!isInterlude && old.isVisible)
            let layer = row.layer
            let delay = reduce ? 0 : Metrics.staggerStep * Double(abs(r - activeRow))
            let animate = animated && old.isVisible && show
            let targetOpacity = (isInterlude && !s.isVisible) ? 0 : s.opacity
            let posY = bounds.height - (s.y + heights[r] / 2)
            let posX = (row.line?.isRightAligned ?? false) ? bounds.width - horizontalPadding : horizontalPadding
            let xform = CATransform3DMakeScale(s.scale, s.scale, 1)

            if s.isVisible || show { layer.isHidden = false }
            if s.isVisible { row.line?.loadContent() }

            let fromY = layer.presentation()?.position.y ?? layer.position.y
            let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
            let fromTransform = layer.presentation()?.transform ?? layer.transform
            layer.position = CGPoint(x: posX, y: posY)
            layer.opacity = Float(targetOpacity)
            layer.transform = xform

            if animate && abs(fromY - posY) > 0.5 {
                if reduce { addFade(layer, from: 0, to: Float(targetOpacity)) }
                else if lineTransition { layer.add(ease("position.y", from: fromY, to: posY, delay: delay, layer: layer, line: true), forKey: "scrollY") }
                else { layer.add(spring(from: fromY, to: posY, delay: delay, layer: layer), forKey: "scrollY") }
            }
            if animate && !reduce {
                if abs(Float(targetOpacity) - fromOpacity) > 0.01 {
                    layer.add(ease("opacity", from: fromOpacity, to: Float(targetOpacity), delay: delay, layer: layer, line: lineTransition), forKey: "fadeTo")
                }
                if abs(fromTransform.m11 - s.scale) > 0.001 {
                    layer.add(ease("transform.scale", from: fromTransform.m11, to: s.scale, delay: delay, layer: layer, line: lineTransition), forKey: "scaleTo")
                }
            } else if !animate { layer.removeAnimation(forKey: "scrollY") }

            applyBlur(layer, radius: (wantBlur && show) ? s.blurRadius : -1, previous: lastBlur[r],
                      animate: animate && !reduce, delay: delay, line: lineTransition)
            lastBlur[r] = (wantBlur && show) ? s.blurRadius : 0
            var stored = s
            stored.isVisible = s.isVisible || show
            lastStyles[r] = stored
        }
        CATransaction.commit()
        scheduleCleanup(styles: styles)
    }

    private func addFade(_ layer: CALayer, from: Float, to: Float) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = Metrics.reducedFade
        layer.add(a, forKey: "reducedFade")
    }

    private func ease(_ key: String, from: Any, to: Any, delay: CFTimeInterval, layer: CALayer, line: Bool = false) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        a.duration = line ? Metrics.lineTransition : Metrics.transition
        a.timingFunction = line ? CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                                : CAMediaTimingFunction(name: .easeInEaseOut)
        a.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        a.fillMode = .backwards
        return a
    }

    /// Critically damped spring with a 0.5 s response (PLAN 4.2): k = (2 pi / response)^2, c = 2 zeta sqrt(k).
    private func spring(from: CGFloat, to: CGFloat, delay: CFTimeInterval, layer: CALayer) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: "position.y")
        let omega = 2 * CGFloat.pi / Metrics.springResponse
        a.mass = 1
        a.stiffness = omega * omega
        a.damping = 2 * Metrics.springDamping * omega
        a.fromValue = from
        a.toValue = to
        a.duration = a.settlingDuration
        a.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        a.fillMode = .backwards
        return a
    }

    /// `radius < 0` removes the filter (hidden row, feature off, or user scrolling).
    private func applyBlur(_ layer: CALayer, radius: CGFloat, previous: CGFloat, animate: Bool, delay: CFTimeInterval, line: Bool = false) {
        guard radius >= 0 else {
            if layer.filters != nil { layer.filters = nil }
            return
        }
        if layer.filters == nil {
            guard let f = CIFilter(name: "CIGaussianBlur") else { return }
            f.name = "blur"
            f.setValue(radius, forKey: kCIInputRadiusKey)
            layer.filters = [f]
            return
        }
        guard abs(radius - previous) > 0.01 else { return }
        layer.setValue(radius, forKeyPath: "filters.blur.\(kCIInputRadiusKey)")
        if animate {
            let a = ease("filters.blur.\(kCIInputRadiusKey)", from: previous, to: radius, delay: delay, layer: layer, line: line)
            layer.add(a, forKey: "blurTo")
        }
    }

    /// After the move settles: hide and unload rows that ended outside the viewport.
    private func scheduleCleanup(styles: [LyricsLayout.RowStyle]) {
        cleanupWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.rows.count == styles.count else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (r, row) in self.rows.enumerated() where !styles[r].isVisible {
                row.layer.isHidden = true
                row.layer.filters = nil
                row.line?.unloadContent()
                self.lastStyles[r].isVisible = false
                self.lastBlur[r] = 0
            }
            CATransaction.commit()
        }
        cleanupWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.cleanupDelay, execute: work)
    }

    // MARK: Input

    override func scrollWheel(with event: NSEvent) {
        guard document != nil, !rows.isEmpty else { super.scrollWheel(with: event); return }
        if !isUserScrolling {
            isUserScrolling = true
            frozenOffset = currentOffset
            onUserScrollChange?(true)
        }
        let heights = rowHeights()
        let tops = LyricsLayout.contentTops(heights: heights, spacing: spacing)
        let contentEnd = (tops.last ?? 0) + (heights.last ?? 0)
        let lo = -Metrics.verticalPadding
        let hi = max(contentEnd - bounds.height + Metrics.verticalPadding, lo)
        frozenOffset = min(max(frozenOffset - event.scrollingDeltaY, lo), hi)
        applyLayout(animated: false)
        if !isStatic { scheduleResume() }
    }

    private func scheduleResume() {
        resumeTimer?.invalidate()
        resumeTimer = Timer.scheduledTimer(withTimeInterval: Metrics.userScrollResume, repeats: false) { [weak self] _ in
            self?.endUserScroll()
            self?.applyLayout(animated: true)
        }
    }

    private func endUserScroll() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        let was = isUserScrolling
        isUserScrolling = false
        if was { onUserScrollChange?(false) }
    }

    /// A press that moves farther than this is a window drag, not a click (PLAN 12.6).
    static let dragThreshold: CGFloat = 4

    /// Pure click/drag discrimination: true once `current` is farther than the threshold from `start`.
    static func isDrag(from start: CGPoint, to current: CGPoint, threshold: CGFloat = dragThreshold) -> Bool {
        hypot(current.x - start.x, current.y - start.y) > threshold
    }

    /// With click-to-seek off the view must not consume presses: the window then drags from
    /// any lyric spot. With it on, presses come to us and `mouseDragged` starts the drag.
    override var mouseDownCanMoveWindow: Bool { !(preferences.clickToSeek && document != nil) }

    private var pressStart: CGPoint?
    private var pressEvent: NSEvent?

    override func mouseDown(with event: NSEvent) {
        guard preferences.clickToSeek, document != nil else { super.mouseDown(with: event); return }
        pressStart = event.locationInWindow
        pressEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressStart, let down = pressEvent else { super.mouseDragged(with: event); return }
        guard Self.isDrag(from: start, to: event.locationInWindow) else { return }
        pressStart = nil; pressEvent = nil          // no seek for this press
        if let window, window.isMovableByWindowBackground { window.performDrag(with: down) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = pressStart else { super.mouseUp(with: event); return }
        pressStart = nil; pressEvent = nil
        guard !Self.isDrag(from: start, to: event.locationInWindow), let doc = document,
              let i = lineIndex(atWindowPoint: start) else { return }
        onSeek?(doc.lines[i].begin)
    }

    /// The visible line under a window-coordinate point, if any.
    private func lineIndex(atWindowPoint point: CGPoint) -> Int? {
        let yTop = bounds.height - convert(point, from: nil).y
        for (r, row) in rows.enumerated() {
            guard case .line(let i) = row.kind, lastStyles[r].isVisible else { continue }
            let s = lastStyles[r]
            if yTop >= s.y - spacing / 2 && yTop <= s.y + row.textHeight + spacing / 2 { return i }
        }
        return nil
    }
}
