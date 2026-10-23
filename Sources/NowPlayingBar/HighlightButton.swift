import AppKit
import QuartzCore

/// Plain icon button with a round hover / press highlight behind the glyph.
/// Hover: faint circle. Press: stronger circle and a slight scale-up; on HDR
/// (EDR) screens in Dark appearance the pressed circle glows brighter than SDR white.
final class HighlightButton: NSButton {
    private let highlight = CALayer()
    private var hovering = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    private static let pressScale: CGFloat = 1.06
    private static let hoverAlpha: CGFloat = 0.10
    private static let pressAlpha: CGFloat = 0.20
    private static let pressAlphaSDR: CGFloat = 0.30   // "stronger highlight" fallback
    private static let hdrHeadroom: CGFloat = 1.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        highlight.zPosition = -1                 // behind the glyph drawn into the button layer
        highlight.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(highlight)
    }

    override func layout() {
        super.layout()
        let d = min(bounds.width, bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        highlight.cornerRadius = d / 2
        CATransaction.commit()
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // The card's panel never activates the app, hence `.activeAlways`.
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; update(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; update(animated: true) }

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

    /// Back to the idle look (card closed / hidden).
    func resetState() {
        hovering = false
        pressed = false
        update(animated: false)
    }

    // MARK: - Look

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// True when the current screen can show brighter-than-SDR-white content.
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
