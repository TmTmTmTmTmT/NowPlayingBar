import AppKit
import QuartzCore

/// The "..." row shown during a long instrumental gap (PLAN 4.1). Dots light up with
/// the gap's progress and breathe while the row is current.
final class InterludeLayer: CALayer {
    enum Metrics {
        static let dotEm: CGFloat = 0.42
        static let gapRatio: CGFloat = 0.7
        static let dimOpacity: Float = 0.35
        static let breathScale: CGFloat = 0.9
        static let breathDuration: CFTimeInterval = 1.2
    }

    let height: CGFloat
    private let dots: [CAShapeLayer]
    private let host = CALayer()
    private var palette: LyricPalette
    private var appearance: NSAppearance
    private var progress: CGFloat = 0

    init(fontSize: CGFloat, width: CGFloat, palette: LyricPalette, appearance: NSAppearance) {
        let d = (fontSize * Metrics.dotEm).rounded()
        height = (fontSize * 0.9).rounded()
        dots = (0..<3).map { _ in CAShapeLayer() }
        self.palette = palette
        self.appearance = appearance
        super.init()
        let inset = LyricLineLayer.Metrics.inset
        bounds = CGRect(x: 0, y: 0, width: width + 2 * inset, height: height + 2 * inset)
        anchorPoint = CGPoint(x: inset / bounds.width, y: 0.5)
        let gap = d * Metrics.gapRatio
        host.bounds = CGRect(x: 0, y: 0, width: 3 * d + 2 * gap, height: d)
        host.anchorPoint = CGPoint(x: 0, y: 0.5)
        host.position = CGPoint(x: inset, y: bounds.midY)
        for (i, dot) in dots.enumerated() {
            dot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: d, height: d), transform: nil)
            dot.frame = CGRect(x: CGFloat(i) * (d + gap), y: 0, width: d, height: d)
            host.addSublayer(dot)
        }
        addSublayer(host)
        applyColors()
        setProgress(0)
    }

    override init(layer: Any) {
        let o = layer as! InterludeLayer
        height = o.height; dots = o.dots; palette = o.palette; appearance = o.appearance
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyColors() {
        let c = LyricPalette.resolve(palette.active, in: appearance)
        dots.forEach { $0.fillColor = c }
    }

    func rerender(palette: LyricPalette, appearance: NSAppearance) {
        self.palette = palette
        self.appearance = appearance
        applyColors()
    }

    /// Dot k is fully lit once the gap is (k + 1) / 3 done.
    func setProgress(_ p: CGFloat) {
        progress = min(max(p, 0), 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, dot) in dots.enumerated() {
            let lit = min(max(progress * 3 - CGFloat(i), 0), 1)
            dot.opacity = Metrics.dimOpacity + (1 - Metrics.dimOpacity) * Float(lit)
        }
        CATransaction.commit()
    }

    func setBreathing(_ on: Bool) {
        if on {
            guard host.animation(forKey: "breath") == nil else { return }
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = Metrics.breathScale
            a.toValue = 1.0
            a.duration = Metrics.breathDuration
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            host.add(a, forKey: "breath")
        } else {
            host.removeAnimation(forKey: "breath")
        }
    }
}
