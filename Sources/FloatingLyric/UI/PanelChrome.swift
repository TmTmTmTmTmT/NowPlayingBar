import AppKit
import QuartzCore

/// Plain icon button with a round hover / press highlight behind the glyph.
/// Same numbers as the host's `HighlightButton` (copied: FloatingLyric must not
/// depend on the app target).
final class LyricHighlightButton: NSButton {
    private let highlight = CALayer()
    private var hovering = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    private static let pressScale: CGFloat = 1.06
    private static let hoverAlpha: CGFloat = 0.10
    private static let pressAlpha: CGFloat = 0.20
    private static let pressAlphaSDR: CGFloat = 0.30
    private static let hdrHeadroom: CGFloat = 1.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        highlight.zPosition = -1                 // behind the glyph drawn into the button layer
        highlight.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(highlight)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let d = min(bounds.width, bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        highlight.cornerRadius = d / 2
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // The lyric panel never activates the app, hence `.activeAlways`.
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; update(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; update(animated: true) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        update(animated: true)
        super.mouseDown(with: event)             // tracking loop; fires the action on release inside
        pressed = false
        if let window {
            hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        update(animated: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { resetState() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update(animated: false)
    }

    /// Back to the idle look (panel hidden).
    func resetState() {
        hovering = false
        pressed = false
        update(animated: false)
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var screenSupportsEDR: Bool {
        (window?.screen ?? NSScreen.main)?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1 > 1.0
    }

    private func color(alpha: CGFloat, hdr: Bool) -> CGColor {
        let base: CGFloat = isDark ? 1 : 0
        if hdr, let space = CGColorSpace(name: CGColorSpace.extendedSRGB) {
            let v = Self.hdrHeadroom
            if let c = CGColor(headroom: Float(v), colorSpace: space, red: v, green: v, blue: v, alpha: alpha) { return c }
        }
        return NSColor(white: base, alpha: alpha).cgColor
    }

    private func update(animated: Bool) {
        let useHDR = pressed && isDark && screenSupportsEDR
        let target: CGColor
        if pressed {
            target = useHDR ? color(alpha: Self.pressAlpha, hdr: true)
                            : color(alpha: Self.pressAlphaSDR, hdr: false)
        } else if hovering {
            target = color(alpha: Self.hoverAlpha, hdr: false)
        } else {
            target = NSColor.clear.cgColor
        }
        let scale: CGFloat = pressed ? Self.pressScale : 1

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? (pressed ? 0.10 : (hovering ? 0.12 : 0.20)) : 0)
        CATransaction.setDisableActions(!animated)
        highlight.preferredDynamicRange = useHDR ? .constrainedHigh : .standard
        highlight.backgroundColor = target
        applyScale(scale, animated: animated)
        CATransaction.commit()
    }

    /// Scale the whole button (glyph + circle) about its center.
    private func applyScale(_ s: CGFloat, animated: Bool) {
        guard let layer else { return }
        let ax = layer.anchorPoint.x * bounds.width, ay = layer.anchorPoint.y * bounds.height
        let cx = bounds.width / 2 - ax, cy = bounds.height / 2 - ay
        var t = CATransform3DMakeTranslation(cx, cy, 0)
        t = CATransform3DScale(t, s, s, 1)
        t = CATransform3DTranslate(t, -cx, -cy, 0)
        if animated {
            let a = CABasicAnimation(keyPath: "transform")
            a.fromValue = layer.presentation()?.transform ?? layer.transform
            a.toValue = t
            a.duration = CATransaction.animationDuration()
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(a, forKey: "pressScale")
        }
        layer.transform = t
    }
}

/// Panel root: frosted blur + one system Liquid Glass surface whose content is the
/// tab container (lyrics and playlist views, plus the tab buttons). Same structure
/// as the host card's `makePanel()` so both always look alike (GUIDELINES 3, 4).
final class PanelChrome: NSView {
    enum Metrics {
        static let buttonSize: CGFloat = 24
        static let buttonSpacing: CGFloat = 6
        static let buttonEdge: CGFloat = 10
        static let crossFade: CFTimeInterval = 0.25
        static let reducedFade: CFTimeInterval = 0.2
    }

    /// Called when the user clicks a tab button.
    var onTabSelected: ((LyricPreferences.Tab) -> Void)?

    let lyricsView: LyricsView
    let playlistView: PlaylistView

    private let blur = NSVisualEffectView()
    var blurViewForTesting: NSVisualEffectView { blur }
    private let dim = NSView()
    var dimViewForTesting: NSView { dim }
    var glassForTesting: NSGlassEffectView { glass }
    private let glass = NSGlassEffectView()
    private let container = NSView()
    private let lyricsButton = LyricHighlightButton(frame: .zero)
    private let playlistButton = LyricHighlightButton(frame: .zero)

    private(set) var tab: LyricPreferences.Tab = .lyrics
    private(set) var placement: LyricPreferences.Placement = .belowCard
    private var tabsAvailable = false
    private var solidElements = false

    init(lyricsView: LyricsView, playlistView: PlaylistView) {
        self.lyricsView = lyricsView
        self.playlistView = playlistView
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true          // clip glass/blur/dim to the rounded shape (F16 3a)
        layer?.cornerRadius = PanelGeometry.cornerRadius(.belowCard)

        glass.tintColor = nil
        glass.autoresizingMask = [.width, .height]
        glass.frame = bounds

        blur.material = .menu
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = []
        blur.frame = bounds
        blur.wantsLayer = true
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        dim.autoresizingMask = []
        dim.frame = bounds
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.cgColor
        dim.layer?.cornerCurve = .continuous
        dim.layer?.masksToBounds = true
        dim.isHidden = true

        container.frame = bounds
        container.autoresizingMask = [.width, .height]
        for v in [lyricsView, playlistView] {
            v.frame = container.bounds
            v.autoresizingMask = [.width, .height]
            container.addSubview(v)
        }
        playlistView.isHidden = true
        playlistView.alphaValue = 0
        setUpButton(lyricsButton, symbol: "quote.bubble", tab: .lyrics)
        setUpButton(playlistButton, symbol: "list.bullet", tab: .playlist)

        glass.contentView = container
        addSubview(blur)
        addSubview(dim)
        addSubview(glass)
        configure(placement: placement, tabsAvailable: false)
        apply(glass: .regular)
        updateButtonColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func setUpButton(_ b: LyricHighlightButton, symbol: String, tab: LyricPreferences.Tab) {
        b.isBordered = false
        b.title = ""
        b.imagePosition = .imageOnly
        b.imageScaling = .scaleNone
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        b.tag = tab.rawValue
        b.target = self
        b.action = #selector(tabClicked(_:))
        b.autoresizingMask = [.minXMargin, .maxYMargin]
        container.addSubview(b)
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard let t = LyricPreferences.Tab(rawValue: sender.tag) else { return }
        onTabSelected?(t)
    }

    // MARK: Glass

    /// Mirrors the host's `applyGlassPrefs()`. The pinned Light/Dark look goes on this
    /// root view only; the content views inherit it (PLAN 11.1, #8).
    func apply(glass g: GlassAppearance) {
        glass.style = g.isClear ? .clear : .regular
        appearance = NSAppearance(named: .darkAqua)   // all glass is dark (PLAN 12.25)
        blur.material = g.blurMaterial
        blur.alphaValue = g.blurOpacity
        blur.isHidden = g.blurHidden
        let frostOn = g.isClear && !g.blurHidden
        dim.alphaValue = g.dimAlpha
        dim.isHidden = !(frostOn && g.dimAlpha > 0)
        glass.tintColor = frostOn && g.glassTintAlpha > 0 ? NSColor(white: 0, alpha: g.glassTintAlpha) : nil
        solidElements = g.solidElements
        updateButtonColors()
    }

    // MARK: Placement

    /// Corner radius, tab buttons and layout per placement.
    func configure(placement: LyricPreferences.Placement, tabsAvailable: Bool) {
        self.placement = placement
        self.tabsAvailable = tabsAvailable
        let r = PanelGeometry.cornerRadius(placement)
        glass.cornerRadius = r
        layer?.cornerRadius = r
        blur.layer?.cornerRadius = r
        dim.layer?.cornerRadius = r
        let showButtons = tabsAvailable && placement != .belowMenuBar
        lyricsButton.isHidden = !showButtons
        playlistButton.isHidden = !showButtons
        if !showButtons && tab == .playlist { setTab(.lyrics, animated: false) }
        needsLayout = true
        layoutButtons()
    }

    override func layout() {
        super.layout()
        blur.frame = bounds
        dim.frame = bounds
        layoutButtons()
    }

    private func layoutButtons() {
        let s = Metrics.buttonSize
        let y = Metrics.buttonEdge
        let right = container.bounds.width - Metrics.buttonEdge
        playlistButton.frame = NSRect(x: right - s, y: y, width: s, height: s)
        lyricsButton.frame = NSRect(x: right - 2 * s - Metrics.buttonSpacing, y: y, width: s, height: s)
    }

    // MARK: Tabs

    /// Cross-fades to `new` (0.25 s); `animated: false` switches at once.
    func setTab(_ new: LyricPreferences.Tab, animated: Bool) {
        guard new != tab else { return }
        let from = view(for: tab), to = view(for: new)
        tab = new
        updateButtonColors()
        to.isHidden = false
        // Buttons stay on top of the fading content.
        container.addSubview(lyricsButton)
        container.addSubview(playlistButton)
        guard animated, window != nil else {
            to.alphaValue = 1
            from.alphaValue = 0
            from.isHidden = true
            return
        }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduce ? Metrics.reducedFade : Metrics.crossFade
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            from.animator().alphaValue = 0
            to.animator().alphaValue = 1
        }, completionHandler: { [weak self, weak from] in
            // A newer switch may have brought this view back.
            guard let self, let from, self.view(for: self.tab) !== from else { return }
            from.isHidden = true
        })
    }

    private func view(for tab: LyricPreferences.Tab) -> NSView {
        tab == .lyrics ? lyricsView : playlistView
    }

    private func updateButtonColors() {
        let selected = solidElements ? PlaylistPalette.solidColor(alpha: 1) : NSColor.labelColor
        let other = solidElements ? PlaylistPalette.solidColor(alpha: 0.8) : NSColor.secondaryLabelColor
        lyricsButton.contentTintColor = tab == .lyrics ? selected : other
        playlistButton.contentTintColor = tab == .playlist ? selected : other
    }

    /// Back to idle button looks when the panel hides.
    func resetButtons() {
        lyricsButton.resetState()
        playlistButton.resetState()
    }
}
