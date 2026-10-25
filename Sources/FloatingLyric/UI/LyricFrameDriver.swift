import AppKit
import QuartzCore

/// Owns the display link of a view. The link retains its target, so the target is a
/// small proxy and `stop()` must run whenever the view stops needing frames
/// (GUIDELINES 5).
final class LyricFrameDriver {
    private final class Target: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func frame(_ link: CADisplayLink) { handler() }
    }

    private var link: CADisplayLink?
    private let handler: () -> Void

    init(handler: @escaping () -> Void) { self.handler = handler }

    deinit { link?.invalidate() }

    var isRunning: Bool { link != nil }

    func start(on view: NSView) {
        guard link == nil else { return }
        let l = view.displayLink(target: Target(handler), selector: #selector(Target.frame(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }
}
