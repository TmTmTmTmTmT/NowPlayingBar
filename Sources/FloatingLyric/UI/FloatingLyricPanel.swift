import AppKit
import QuartzCore

/// The lyrics window: borderless, non-activating, transparent. One instance serves
/// all three placements; `apply(placement:)` switches level, spaces behavior and
/// click handling (PLAN 11.2). Main thread only.
final class FloatingLyricPanel: ActiveGlassPanel {
    enum Metrics {
        /// Same curves and durations as the host card (GUIDELINES 3).
        static let fadeIn: TimeInterval = 0.207
        static let fadeOut: TimeInterval = 0.184
        static let resize: TimeInterval = 0.25
        static let saveDebounce: TimeInterval = 0.3
    }

    // Same reason as the host card: the buttons' glass renders active only in a key-capable window.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    let chrome: PanelChrome
    private(set) var placement: LyricPreferences.Placement = .belowCard

    /// The floating panel moved without our own frame change (the user's drag); `frame` is its
    /// new frame. Debounced.
    var onUserMoved: ((NSRect) -> Void)?

    /// Tests build the panel without putting it on screen.
    var suppressOrdering = false

    /// Frame changes we make ourselves (set frame, slide ticks, animated resize) run inside this
    /// counter, so every other `didMove` is the user's (FIX_GUIDE F9).
    private var programmaticMoves = 0
    // In-flight slide (PLAN 12.1): driven by a display link so a newer request can cancel it.
    private var slideLink: CADisplayLink?
    private var slideFrom = NSRect.zero
    private var slideStart: CFTimeInterval = 0
    /// Where the running slide ends; nil when not sliding.
    private(set) var slideTarget: NSRect?
    private var saveWork: DispatchWorkItem?
    private var moveObserver: NSObjectProtocol?
    /// Bumped by every fade so a stale completion cannot order the panel out.
    private var fadeGeneration = 0

    init(chrome: PanelChrome) {
        self.chrome = chrome
        super.init(contentRect: NSRect(origin: .zero, size: chrome.frame.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Window-level dark, always (FIX_GUIDE F16): glass shadow/ambient follow the window appearance.
        appearance = NSAppearance(named: .darkAqua)
        isFloatingPanel = true
        // Not hidesOnDeactivate: an accessory app is never active (see the host card).
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = chrome
        chrome.autoresizingMask = [.width, .height]
        // No queue: delivered synchronously inside the move, so the counter above is still set.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: self, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didMove() }
        }
    }

    deinit {
        slideLink?.invalidate()
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        saveWork?.cancel()
    }

    // MARK: Placement

    /// Level, spaces behavior and interaction flags for a placement. Does not move the window.
    func apply(placement p: LyricPreferences.Placement, locked: Bool, clickThrough: Bool) {
        placement = p
        switch p {
        case .floating:
            level = .floating
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        case .belowCard:
            level = .statusBar
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        case .belowMenuBar:
            level = .statusBar
            collectionBehavior = [.canJoinAllSpaces, .stationary]
        }
        // Only the floating panel is draggable; floating and below-menu-bar can be click-through.
        isMovableByWindowBackground = p == .floating && !locked
        ignoresMouseEvents = (p == .floating || p == .belowMenuBar) && clickThrough
    }

    /// Sets the frame; animates (0.25 s) only when the panel is on screen and the size changes.
    func setPanelFrame(_ new: NSRect, animated: Bool) {
        if slideTarget != nil {
            slideTarget = new                // retarget the running slide; never fight it
            return
        }
        guard new != frame else { return }
        let animate = animated && isVisible && new.size != frame.size
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate {
            // Steps of the animation post moves too: count them until it completes.
            programmaticMoves += 1
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Metrics.resize
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(new, display: true)
            }, completionHandler: { [weak self] in
                self?.programmaticMoves -= 1
            })
        } else {
            setFrameProgrammatically(new)
        }
    }

    private func setFrameProgrammatically(_ new: NSRect) {
        programmaticMoves += 1
        setFrame(new, display: true)
        programmaticMoves -= 1
    }

    /// Moves to `target` over 0.30 s with the card curve, starting from wherever the window is
    /// now. Replaces a running slide. Jumps when hidden, unchanged, or Reduce Motion is on.
    func slide(to target: NSRect) {
        cancelSlide()
        guard isVisible, target != frame, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if target != frame { setFrameProgrammatically(target) }
            return
        }
        slideFrom = frame
        slideTarget = target
        slideStart = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(slideTick(_:)))
        link.add(to: .main, forMode: .common)
        slideLink = link
    }

    @objc private func slideTick(_ link: CADisplayLink) {
        guard let target = slideTarget else { cancelSlide(); return }
        let t = (CACurrentMediaTime() - slideStart) / PanelGeometry.slideDuration
        if t >= 1 {
            cancelSlide()
            setFrameProgrammatically(target)
        } else {
            setFrameProgrammatically(PanelGeometry.interpolate(from: slideFrom, to: target,
                                                               progress: PanelGeometry.eased(t)))
        }
    }

    private func cancelSlide() {
        slideLink?.invalidate()
        slideLink = nil
        slideTarget = nil
    }

    // MARK: Fades

    /// Orders the panel in (without activating) and fades it up over 0.207 s.
    func fadeIn(duration: TimeInterval = Metrics.fadeIn) {
        fadeGeneration += 1
        guard !suppressOrdering else { return }
        if !isVisible { alphaValue = 0 }
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    /// Fades out over 0.184 s, then orders out unless a newer fade started.
    /// `orderOut: false` keeps the window (child windows are removed by the caller).
    func fadeOut(orderOut: Bool = true, completion: (() -> Void)? = nil) {
        guard isVisible else { completion?(); return }
        fadeGeneration += 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Metrics.fadeOut
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, generation == self.fadeGeneration else { return }
            chrome.resetButtons()
            if orderOut { self.orderOut(nil) }
            completion?()
        })
    }

    // MARK: Moves

    /// Background drags run inside the window server and report their moves after `sendEvent`
    /// returns, so a drag cannot be told apart by event timing: anything that is not our own
    /// frame change counts as the user's while floating.
    private func didMove() {
        guard programmaticMoves == 0, placement == .floating else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.placement == .floating else { return }
            self.onUserMoved?(self.frame)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.saveDebounce, execute: work)
    }
}
