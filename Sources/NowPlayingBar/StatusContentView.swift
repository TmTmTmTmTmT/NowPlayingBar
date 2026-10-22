import AppKit

/// The status item content: plain title text, no background, no icon.
/// Width is sized to the text; transitions use opacity only (no width animation)
/// so the menu bar is never relaid-out during animation.
final class StatusContentView: NSView {
    private let marquee = MarqueeView(frame: .zero)
    private let sidePad: CGFloat = 4

    // MARK: - Sizing

    /// The width this view should occupy for the current title.
    func fittingWidth() -> CGFloat {
        marquee.fittingWidth + sidePad * 2
    }

    // MARK: - Preferences

    var marqueeMaxWidth: CGFloat {
        get { marquee.maxWidth }
        set { marquee.maxWidth = newValue }
    }
    var scrollSpeed: CGFloat {
        get { marquee.pointsPerSecond }
        set { marquee.pointsPerSecond = newValue }
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true   // needed for alphaValue animation
        addSubview(marquee)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Let clicks fall through to the button so the menu opens.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Content

    func setTitle(_ title: String) { marquee.setText(title) }
    func clearTitle()              { marquee.setText("") }
    func setHighlighted(_ flag: Bool) { marquee.recolor(highlighted: flag) }

    /// Dim the title while paused. Animates only the inner marquee's alpha —
    /// `alphaValue` of this view belongs to the show / hide / crossfade code.
    /// Independent of the highlight color, so it holds while highlighted too.
    func setPaused(_ paused: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            marquee.animator().alphaValue = paused ? 0.5 : 1.0
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        marquee.frame = NSRect(
            x: sidePad, y: 0,
            width: max(0, bounds.width - sidePad * 2),
            height: bounds.height
        )
    }
}
