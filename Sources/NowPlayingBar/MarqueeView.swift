import AppKit
import QuartzCore

/// A menu-bar text view that shows a title and, when the title is wider than
/// `maxWidth`, slowly scrolls it leftward — revealing the full text via Core
/// Animation (two CATextLayer copies + repeating CABasicAnimation on position.x).
final class MarqueeView: NSView {
    var maxWidth: CGFloat = 220 {
        didSet { if maxWidth != oldValue { needsLayout = true } }
    }
    var pointsPerSecond: CGFloat = 40 {
        didSet { if pointsPerSecond != oldValue { needsLayout = true } }
    }
    var pauseAtStart: CFTimeInterval = 1.5

    private var highlighted = false
    private let sidePadding: CGFloat = 2
    private let gap: CGFloat = 42

    private var text: String = ""
    /// Menu-bar size, but a touch heavier than the system regular weight.
    /// Configurable so the same view can be reused in the control panel.
    var font: NSFont = {
        let base = NSFont.menuBarFont(ofSize: 0)
        return NSFont.systemFont(ofSize: base.pointSize, weight: .medium)
    }() {
        didSet {
            guard font != oldValue else { return }
            _cachedTextSize = nil
            needsLayout = true
        }
    }
    /// Resting text color (overridden white while highlighted).
    var baseColor: NSColor = .labelColor {
        didSet { if baseColor != oldValue { recolor(highlighted: highlighted) } }
    }
    private var textLayers: [CATextLayer] = []

    // Single measurement used by both fittingWidth and rebuild().
    // Recomputed lazily whenever text changes.
    private var _cachedTextSize: CGSize?
    private var cachedTextSize: CGSize {
        if let c = _cachedTextSize { return c }
        guard !text.isEmpty else { return .zero }
        let s = (text as NSString).size(withAttributes: [.font: font])
        _cachedTextSize = s
        return s
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Sizing

    var fittingWidth: CGFloat {
        guard !text.isEmpty else { return 0 }
        return min(ceil(cachedTextSize.width), maxWidth) + sidePadding * 2
    }

    // MARK: - Content

    func setText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        _cachedTextSize = nil   // invalidate measurement cache
        needsLayout = true      // rebuild deferred to layout() — no double-rebuild
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != bounds.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }   // layout() will rebuild once
    }

    /// Single authoritative rebuild path — driven by AppKit's layout system.
    override func layout() {
        super.layout()
        rebuild()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor(highlighted: highlighted)
    }

    /// Recolors layers in place — no teardown, scroll keeps running.
    func recolor(highlighted: Bool) {
        self.highlighted = highlighted
        guard !text.isEmpty, !textLayers.isEmpty else { return }
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: resolvedTextColor()]
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayers.forEach { $0.string = attributed }
        CATransaction.commit()
    }

    // MARK: - Rendering

    private func rebuild() {
        textLayers.forEach { $0.removeFromSuperlayer() }
        textLayers.removeAll()

        guard !text.isEmpty, bounds.width > 1, let host = layer else { return }

        let sz = cachedTextSize           // single measurement
        let tw = ceil(sz.width)
        let lh = ceil(sz.height)
        let y  = (bounds.height - lh) / 2
        let available = bounds.width - sidePadding * 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if tw <= available {
            let layer = makeTextLayer()
            layer.frame = CGRect(x: sidePadding, y: y, width: tw + 2, height: lh)
            host.addSublayer(layer)
            textLayers = [layer]
        } else {
            let copyWidth = tw + gap
            let first  = makeTextLayer()
            first.frame  = CGRect(x: sidePadding, y: y, width: tw + 2, height: lh)
            let second = makeTextLayer()
            second.frame = CGRect(x: sidePadding + copyWidth, y: y, width: tw + 2, height: lh)
            host.addSublayer(first)
            host.addSublayer(second)
            textLayers = [first, second]
            addScrollAnimation(distance: copyWidth)
        }
    }

    private func makeTextLayer() -> CATextLayer {
        let layer = CATextLayer()
        layer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        layer.isWrapped = false
        layer.truncationMode = .none
        layer.alignmentMode = .left
        layer.string = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: resolvedTextColor()]
        )
        return layer
    }

    private func addScrollAnimation(distance: CGFloat) {
        let duration = CFTimeInterval(distance / max(pointsPerSecond, 1))
        for layer in textLayers {
            let startX = layer.position.x
            let scroll = CABasicAnimation(keyPath: "position.x")
            scroll.fromValue = startX
            scroll.toValue   = startX - distance
            scroll.duration  = duration
            scroll.beginTime = pauseAtStart
            scroll.timingFunction = CAMediaTimingFunction(name: .linear)

            let group = CAAnimationGroup()
            group.animations          = [scroll]
            group.duration            = duration + pauseAtStart
            group.repeatCount         = .greatestFiniteMagnitude
            group.isRemovedOnCompletion = false
            layer.add(group, forKey: "marquee")
        }
    }

    private func resolvedTextColor() -> NSColor {
        if highlighted { return .white }
        var color = baseColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = baseColor.usingColorSpace(.sRGB) ?? baseColor
        }
        return color
    }
}
