import AppKit
import FloatingLyric

/// Borderless panel that can become key without activating the app — glass
/// buttons render dimmed in a non-key window. `ActiveGlassPanel` keeps the
/// glass rim highlight when the card stays up while another app is active.
final class CardPanel: ActiveGlassPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let scriptURL: URL
    private let frameworkURL: URL
    private let monitor: NowPlayingMonitor
    private let prefs = Preferences.shared

    private var statusItem: NSStatusItem!
    private var content: StatusContentView!
    private let menu = NSMenu()

    /// Left-click control card (artwork + transport + scrubber), hosted in a
    /// borderless glass panel (no popover arrow).
    private var panel: CardPanel?
    private var glassView: NSGlassEffectView?
    private var dimView: NSView?
    private var blurView: NSVisualEffectView?   // menu-like frosted blur behind clear glass
    private var controls: NowPlayingPopoverController!
    private var dismissMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var panelIsShown: Bool { panel?.isVisible ?? false }

    // Card modes (Preferences.cardMode). `cardActive` is the logical state:
    // true from the moment a show begins until a hide begins (`panelIsShown`
    // stays true during the fade-out).
    private var cardActive = false
    private var cardShowPending = false
    private var cardAutoRetries = 0
    /// Always-shown modes: user hid the card via the widget; not persisted.
    private var cardTemporarilyHidden = false
    private var cardFollowItem: DispatchWorkItem?
    private var isAlwaysShown: Bool { prefs.cardMode != 0 }
    /// Lyrics are on, either by preference or forced by "Always shown with Lyrics Card".
    private var lyricsActive: Bool { lyricPrefs.enabled || prefs.cardMode == 2 }

    /// Fade-in target (the glass has its own translucency).
    private let panelAlpha: CGFloat = 1.0

    private var current: NowPlayingInfo?

    /// Lyrics add-on. Fed from the same filtered state as the menu bar title.
    private var lyrics: FloatingLyricController?
    private weak var observedStatusWindow: NSWindow?
    private var statusWindowObservers: [NSObjectProtocol] = []
    private var statusMoveScheduled = false
    private let lyricPrefs = LyricPreferences.shared
    /// Last track sent to the add-on (dedupes; its duration may arrive late).
    private var lyricsTrack: TrackRef?
    /// Identity + duration of the latest timeline sample, so a stale duration
    /// from the previous track is never attached to a new one.
    private var lastSampleKey: (title: String, source: String)?
    private var lastSampleDuration: TimeInterval = 0

    /// Tracks whether the title is currently visible (or animating in).
    /// Guards against redundant show/hide calls.
    private var isShowing = false

    /// The title string currently on screen. Lets us skip a crossfade when
    /// the displayed text didn't actually change (e.g. play/pause toggle).
    private var displayedTitle: String?

    private let fadeDuration: TimeInterval = 0.437  // show / hide

    /// Track-change crossfade: each leg is the card's transition leg so the
    /// menu bar title and the card animate with the same duration.
    private var transitionLeg: TimeInterval { NowPlayingPopoverController.transitionLeg }
    private let transitionTimeout: TimeInterval = 1.0  // max wait for the card

    // Pending track transition (see crossfade). The token invalidates older
    // waits when a newer track starts or the title is hidden.
    private var transitionToken = 0
    private var transitionText: String?
    private var transitionFadeOutDone = false
    private var transitionAwaitsCard = false
    private var transitionCardReady = false
    private var transitionTimeoutItem: DispatchWorkItem?

    /// Gentle ease-in-out — eased at both ends for the softest start/stop.
    private var smoothCurve: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.33, 0, 0.2, 1)
    }

    init(scriptURL: URL, frameworkURL: URL) {
        self.scriptURL = scriptURL
        self.frameworkURL = frameworkURL
        self.monitor = NowPlayingMonitor(scriptURL: scriptURL, frameworkURL: frameworkURL)
        super.init()
    }

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            // Re-pin right away and once more after the system has settled.
            self?.applyGlassPrefs()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.applyGlassPrefs() }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: 0)
        guard let button = statusItem.button else { return }

        content = StatusContentView(frame: button.bounds)
        content.autoresizingMask = [.width, .height]
        content.marqueeMaxWidth = prefs.maxWidth
        content.scrollSpeed = prefs.scrollSpeed
        content.alphaValue = 0
        button.addSubview(content)

        menu.delegate = self
        menu.autoenablesItems = false

        // Left-click → popover, right-click (or ctrl-click) → options menu.
        // The menu is attached on demand in showMenu() so left-clicks reach
        // our action instead of auto-opening the menu.
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        controls = NowPlayingPopoverController(monitor: monitor)
        controls.showsShuffleRepeat = prefs.showShuffleRepeat
        controls.onTransitionReady = { [weak self] in self?.cardTransitionReady() }

        lyrics = FloatingLyricController(host: LyricHost(
            seek: { [weak self] in self?.monitor.seek(to: $0) },
            statusItemFrame: { [weak self] in
                guard let b = self?.statusItem.button, let w = b.window else { return nil }
                return w.convertToScreen(b.convert(b.bounds, to: nil))
            }))
        lyrics?.onAtmosChange = { [weak self] on in self?.controls.showsAtmos = on }
        lyrics?.setForcedCardAttachment(prefs.cardMode == 2)
        observeStatusItemWindow()
        applyGlassPrefs()

        guard monitor.adapterExists else { return }

        monitor.onUpdate = { [weak self] info in self?.handleUpdate(info) }
        monitor.wantsTimeline = lyricsActive
        monitor.onTimeline = { [weak self] sample in self?.handleTimeline(sample) }
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        lyrics?.setForcedCardAttachment(false)
        monitor.stop()
    }

    // MARK: - State

    private func handleUpdate(_ info: NowPlayingInfo?) {
        // NowPlayingInfo stores only the fields we display (title/artist/isPlaying/
        // sourceBundleID) — not elapsedTime. So equality holds across the ~150ms
        // updates where only elapsed time changed, letting us skip ~99% of redraws.
        guard info != current else { return }

        // Follow only the enabled source(s): ignore updates published by other
        // apps so a second app grabbing system "Now Playing" doesn't blank our
        // source's widget (and isn't misread as our source pausing). We keep the
        // last source state until that source itself reports a change.
        if prefs.filterEnabled, let info, !prefs.shouldDisplay(info.sourceBundleID) {
            return
        }

        current = info
        if let info { prefs.recordDiscovered(id: info.sourceBundleID) }
        updateDisplay()
        if panelIsShown { refreshPanel() }   // track/play change → refresh card
        syncLyricsTrack()
    }

    // MARK: - Lyrics feed

    /// Sends the filtered current track to the add-on (only when it changed).
    private func syncLyricsTrack(force: Bool = false) {
        var ref: TrackRef?
        if let info = current, prefs.shouldDisplay(info.sourceBundleID) {
            let known = lastSampleKey.map { $0 == (info.title, info.sourceBundleID) } ?? false
            ref = TrackRef(title: info.title, artist: info.artist, album: info.album,
                           duration: known ? lastSampleDuration : 0,
                           sourceBundleID: info.sourceBundleID)
        }
        guard force || ref != lyricsTrack else { return }
        lyricsTrack = ref
        lyrics?.update(track: ref)
    }

    private func handleTimeline(_ sample: TimelineSample) {
        // Same source filter as handleUpdate; ignore samples of other tracks.
        if prefs.filterEnabled, !prefs.shouldDisplay(sample.sourceBundleID) { return }
        guard let info = current, info.title == sample.title,
              info.sourceBundleID == sample.sourceBundleID else { return }

        lastSampleKey = (sample.title, sample.sourceBundleID)
        lastSampleDuration = sample.timeline.duration
        // Duration appeared after the track was announced → re-send once.
        if sample.timeline.duration > 0, var t = lyricsTrack, t.duration == 0 {
            t.duration = sample.timeline.duration
            lyricsTrack = t
            lyrics?.update(track: t)
        }
        lyrics?.update(timeline: sample.timeline)
    }

    /// Lyrics were just switched on: the stream only speaks on changes, so
    /// fetch one snapshot to get position + duration right away.
    private func primeLyricsTimeline() {
        monitor.fetchDetail { [weak self] d in
            guard let self, let d, self.lyricsActive else { return }
            self.handleTimeline(TimelineSample(
                timeline: PlaybackTimeline(elapsed: d.elapsedTime, timestamp: d.sampledAt,
                                           rate: d.playbackRate, duration: d.duration,
                                           isPlaying: d.isPlaying),
                sourceBundleID: d.sourceBundleID, title: d.title,
                artist: d.artist, album: d.album))
        }
    }

    // MARK: - Click routing

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRight {
            if panelIsShown && !isAlwaysShown { hidePanel() }
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func showMenu() {
        statusItem.menu = menu                 // attach just for this open
        statusItem.button?.performClick(nil)   // menuDidClose detaches it again
    }

    // MARK: - Control panel

    private func togglePanel() {
        if isAlwaysShown {
            // Temporary hide / show; forgotten on the next launch.
            if cardActive {
                cardTemporarilyHidden = true
                hidePanel()
            } else {
                cardTemporarilyHidden = false
                if displayableInfo() != nil { showPanel(userInitiated: true) }
            }
            return
        }
        panelIsShown ? hidePanel() : showPanel()
    }

    /// Where the card sits: below the status item, centered on the button and
    /// clamped to the screen. `nil` while the button has no window yet.
    private func cardOrigin(for size: NSSize) -> NSPoint? {
        guard let button = statusItem.button, let bwin = button.window else { return nil }
        let btn = bwin.convertToScreen(button.convert(button.bounds, to: nil))
        var x = btn.midX - size.width / 2
        let y = btn.minY - size.height - 15
        if let scr = bwin.screen ?? NSScreen.main {
            x = min(max(x, scr.frame.minX + 8), scr.frame.maxX - size.width - 8)
        }
        return NSPoint(x: x, y: y)
    }

    /// Always-shown modes: shows or hides the card to match whether playback
    /// info exists (same notion as the menu bar title), unless the user hid it.
    private func syncAutoCard() {
        guard isAlwaysShown else { return }
        let want = displayableInfo() != nil && !cardTemporarilyHidden
        if want && !cardActive && !cardShowPending {
            showPanel(userInitiated: false)
        } else if !want && cardActive {
            hidePanel()
        }
    }

    /// The status bar lays the item out asynchronously, so the lyrics also need a signal once the
    /// button window has really moved. Several notifications in one runloop pass count once.
    private func observeStatusItemWindow() {
        guard let window = statusItem.button?.window, window !== observedStatusWindow else { return }
        statusWindowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        observedStatusWindow = window
        statusWindowObservers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                self?.scheduleStatusItemDidMove()
            }
        }
    }

    private func scheduleStatusItemDidMove() {
        guard !statusMoveScheduled else { return }
        statusMoveScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.statusMoveScheduled = false
            self?.lyrics?.statusItemDidMove()
        }
    }

    /// The widget's width changed: re-center the card once the changes settle
    /// (0.25 s debounce) so it doesn't jitter while the title animates.
    private func statusItemMoved() {
        observeStatusItemWindow()
        lyrics?.statusItemDidMove()
        guard isAlwaysShown, cardActive else { return }
        cardFollowItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isAlwaysShown, self.cardActive, let panel = self.panel,
                  let origin = self.cardOrigin(for: panel.frame.size),
                  abs(origin.x - panel.frame.origin.x) > 0.5
                    || abs(origin.y - panel.frame.origin.y) > 0.5 else { return }
            panel.setFrameOrigin(origin)
            self.lyrics?.statusItemDidMove()
        }
        cardFollowItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    /// Always-shown modes: a shuffle/repeat option change alters the card size,
    /// which needs a fresh panel (same path as a manual show).
    private func resizeCardIfNeeded() {
        guard isAlwaysShown, cardActive, let panel, panel.frame.size != controls.cardSize else { return }
        showPanel(userInitiated: false)
    }

    private func showPanel(userInitiated: Bool = true) {
        guard let button = statusItem.button, button.window != nil else { return }
        cardShowPending = true
        monitor.fetchDetail { [weak self] detail in
            guard let self else { return }
            self.cardShowPending = false
            // Auto shows are re-validated: the situation may have changed
            // while the fetch ran.
            if !userInitiated, !self.isAlwaysShown || self.cardTemporarilyHidden
                || self.displayableInfo() == nil { return }
            guard let detail else {
                if !userInitiated, self.cardAutoRetries < 3 {
                    self.cardAutoRetries += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        self?.syncAutoCard()
                    }
                }
                return
            }
            self.cardAutoRetries = 0
            self.controls.apply(detail)

            let size = self.controls.cardSize
            // makePanel() sizes the glass/card to its creation bounds, so a
            // card size change (shuffle & repeat option) needs a fresh panel.
            if let old = self.panel, old.frame.size != size {
                old.orderOut(nil)
                self.panel = nil
            }
            let panel = self.panel ?? self.makePanel()
            self.panel = panel

            // Position below the status item, horizontally centered on the
            // button, clamped to the screen.
            guard let origin = self.cardOrigin(for: size) else { return }
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            self.cardActive = true
            self.lyrics?.cardWillShow(frame: panel.frame, cardWindow: panel)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            // Key (so glass buttons render active) without activating the app.
            // Automatic shows never take key focus from the user's app.
            if userInitiated { panel.makeKey() }

            self.controls.startTicking()
            if !self.isAlwaysShown {
                self.content.setHighlighted(true)
                self.installDismissMonitor()
            }

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.207
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = self.panelAlpha
            }
        }
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        cardActive = false
        cardFollowItem?.cancel()
        lyrics?.cardWillHide()
        controls.stopTicking()
        removeDismissMonitor()
        content.setHighlighted(false)
        // A card hidden mid-transition must not stall the menu bar title.
        if transitionAwaitsCard { cardTransitionReady() }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.184
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            // Don't hide if a new show re-raised the panel during the fade.
            guard let panel, panel.alphaValue < 0.05 else { return }
            panel.orderOut(nil)
            self?.lyrics?.cardDidHide()
        })
    }

    private func refreshPanel() {
        // One fetch; the controller then self-polls for the artwork (which lags
        // the title), so no extra retry is needed here.
        fetchAndApply()
    }

    private func fetchAndApply() {
        monitor.fetchDetail { [weak self] detail in
            guard let self, let detail, self.panelIsShown else { return }
            self.controls.apply(detail)
        }
    }

    private func makePanel() -> CardPanel {
        let size = controls.cardSize
        let panel = CardPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .darkAqua)   // window-level dark, always (FIX_GUIDE F16)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        // NOT hidesOnDeactivate: this is an accessory (LSUIElement) app that is
        // never the active app, so that flag would hide the panel instantly.
        // Dismissal is handled by the global click monitor instead.
        panel.hidesOnDeactivate = false
        // alphaValue is set per-show for the fade; panelAlpha is the target.

        // One system Liquid Glass surface; the card is its content view.
        let bounds = NSRect(origin: .zero, size: size)
        let glass = NSGlassEffectView(frame: bounds)
        glass.tintColor = nil
        glass.cornerRadius = 22      // artwork radius 8 + inner padding 14
        glass.autoresizingMask = [.width, .height]
        glassView = glass

        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .menu
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 22
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blurView = blur

        let dim = NSView(frame: bounds)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.cgColor
        dim.layer?.cornerRadius = 22
        dim.layer?.cornerCurve = .continuous
        dim.layer?.masksToBounds = true
        dim.isHidden = true
        dimView = dim
        applyGlassPrefs()

        let card = controls.view
        card.frame = bounds
        card.autoresizingMask = [.width, .height]
        glass.contentView = card

        let root = NSView(frame: bounds)
        root.wantsLayer = true
        root.layer?.cornerRadius = 22
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true     // clip glass shadow outside the rounded shape (F16 3a)
        root.addSubview(blur)
        root.addSubview(dim)
        root.addSubview(glass)
        panel.contentView = root
        return panel
    }

    /// Clear glass look: menu-material blur, slightly see-through cover.
    private static let clearCoverOpacity: CGFloat = 0.85

    /// Apply the glass option to the live panel.
    private func applyGlassPrefs() {
        let clear = prefs.glassClear
        let look = GlassAppearance.resolved(isClear: clear, noBlur: prefs.clearNoBlur)
        glassView?.style = clear ? .clear : .regular
        // All glass is always dark, regardless of the system Light / Dark (PLAN 12.25).
        let pinned = NSAppearance(named: .darkAqua)
        glassView?.appearance = pinned
        blurView?.appearance = pinned
        let frostOn = clear && !look.blurHidden
        blurView?.material = look.blurMaterial
        blurView?.alphaValue = look.blurOpacity
        blurView?.isHidden = look.blurHidden
        dimView?.alphaValue = look.dimAlpha
        dimView?.isHidden = !(frostOn && look.dimAlpha > 0)
        glassView?.tintColor = frostOn && look.glassTintAlpha > 0 ? NSColor(white: 0, alpha: look.glassTintAlpha) : nil
        controls.solidElements = clear
        controls.artworkAlpha = clear && prefs.clearCoverFade ? Self.clearCoverOpacity : 1
        lyrics?.apply(glass: look)
    }

    // Dismiss the panel when focus leaves it:
    //  - global mouse monitor: any click in another app / the desktop / menu bar
    //    (global monitors fire only for *other* apps, so panel buttons still work)
    //  - workspace activation: another app coming forward (e.g. via ⌘-Tab)
    private func installDismissMonitor() {
        removeDismissMonitor()
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in self?.hidePanel() }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.hidePanel()
        }
    }

    private func removeDismissMonitor() {
        if let m = dismissMonitor { NSEvent.removeMonitor(m); dismissMonitor = nil }
        if let o = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            activationObserver = nil
        }
    }

    private func displayableInfo() -> NowPlayingInfo? {
        guard let info = current else { return nil }
        if prefs.hideWhenPaused && !info.isPlaying { return nil }
        guard prefs.shouldDisplay(info.sourceBundleID) else { return nil }
        return info
    }

    private func displayString(for info: NowPlayingInfo) -> String {
        var parts = [info.title]
        if prefs.showArtist { parts.append(info.artist ?? "") }
        if prefs.showAlbum  { parts.append(info.album ?? "") }
        return parts.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    private func updateDisplay() {
        content.marqueeMaxWidth = prefs.maxWidth
        content.scrollSpeed = prefs.scrollSpeed

        if let info = displayableInfo() {
            showTitle(displayString(for: info))
            // Applies even when the text is unchanged (play ↔ pause toggle).
            content.setPaused(!info.isPlaying)
            controls.setArtworkDimmed(!info.isPlaying)   // same moment and curve as the title
        } else {
            hideTitle()
        }
        syncAutoCard()
    }

    // MARK: - Transitions
    //
    // statusItem.length is set ONCE before fade-in (to size the item)
    // and ONCE after fade-out (to reclaim space). It is never touched during
    // the animation, so the menu bar is not relaid-out every frame.

    private func showTitle(_ text: String) {
        if isShowing {
            // Already visible. If the text is unchanged (e.g. a play/pause
            // toggle), do nothing — no flicker. Otherwise crossfade.
            guard text != displayedTitle else { return }
            crossfade(to: text)
            return
        }

        // First appearance — size, then fade in.
        isShowing = true
        displayedTitle = text
        content.setTitle(text)
        statusItem.length = content.fittingWidth()
        statusItemMoved()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fadeDuration
            ctx.timingFunction = smoothCurve
            content.animator().alphaValue = 1
        }
    }

    /// Track changed while visible: fade the old title out, then swap text +
    /// width and fade the new title in. If the card is open, its transition
    /// runs in lockstep: the title waits (up to 1.0 s) for the card's
    /// "ready" signal so both fade in on the same run-loop turn.
    private func crossfade(to text: String) {
        displayedTitle = text
        transitionToken += 1
        let token = transitionToken
        transitionTimeoutItem?.cancel()
        transitionText = text
        transitionFadeOutDone = false
        transitionCardReady = false
        transitionAwaitsCard = panelIsShown

        if transitionAwaitsCard {
            controls.beginTrackTransition()
            let item = DispatchWorkItem { [weak self] in
                // Stale if a newer transition began (token) — then ignore.
                guard let self, self.transitionToken == token else { return }
                self.cardTransitionReady()
            }
            transitionTimeoutItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + transitionTimeout, execute: item)
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = transitionLeg
            ctx.timingFunction = smoothCurve
            content.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.isShowing, self.displayedTitle == text,
                  self.transitionToken == token else {
                // Hidden or superseded mid-fade — let the newer call own state.
                return
            }
            self.transitionFadeOutDone = true
            self.completeTransitionIfReady()
        })
    }

    /// The card's new track is ready (or it was hidden / timed out).
    private func cardTransitionReady() {
        transitionCardReady = true
        completeTransitionIfReady()
    }

    /// Fade-in once the title has faded out and (if the card is open) the
    /// card is ready — swap text + length, fade in, and let the card fade in
    /// in the same turn.
    private func completeTransitionIfReady() {
        guard transitionFadeOutDone, !transitionAwaitsCard || transitionCardReady,
              isShowing, let text = transitionText, displayedTitle == text else { return }
        let awaitsCard = transitionAwaitsCard
        endTransition()

        content.setTitle(text)
        statusItem.length = content.fittingWidth()
        statusItemMoved()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = transitionLeg
            ctx.timingFunction = smoothCurve
            content.animator().alphaValue = 1
        }
        if awaitsCard { controls.finishTrackTransition() }
    }

    /// Clear pending transition state and invalidate any outstanding waits.
    private func endTransition() {
        transitionToken += 1
        transitionTimeoutItem?.cancel()
        transitionTimeoutItem = nil
        transitionText = nil
        transitionFadeOutDone = false
        transitionAwaitsCard = false
        transitionCardReady = false
    }

    private func hideTitle() {
        guard isShowing else { return }
        isShowing = false
        displayedTitle = nil
        // Drop any pending track transition; don't leave the card faded out.
        let cardWaiting = transitionAwaitsCard
        endTransition()
        if cardWaiting { controls.finishTrackTransition() }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration
            ctx.timingFunction = smoothCurve
            content.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isShowing else {
                // Re-shown during the fade — leave alpha at whatever showTitle set.
                return
            }
            self.statusItem.length = 0
            self.content.clearTitle()
            self.statusItemMoved()
        })
    }

    // MARK: - Menu delegates

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        content.setHighlighted(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        content.setHighlighted(false)
        // Detach so the next left-click hits statusItemClicked, not the menu.
        DispatchQueue.main.async { [weak self] in self?.statusItem.menu = nil }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()

        let sourcesItem = NSMenuItem(title: "Sources", action: nil, keyEquivalent: "")
        sourcesItem.submenu = buildSourcesMenu()
        menu.addItem(sourcesItem)

        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        displayItem.submenu = buildDisplayMenu()
        menu.addItem(displayItem)

        let cardItem = NSMenuItem(title: "Music Card", action: nil, keyEquivalent: "")
        cardItem.submenu = buildCardMenu()
        menu.addItem(cardItem)

        let lyricsItem = NSMenuItem(title: "Lyrics Card", action: nil, keyEquivalent: "")
        lyricsItem.submenu = buildLyricsMenu()
        menu.addItem(lyricsItem)

        menu.addItem(.separator())
        addItem(to: menu, title: "Quit Now Playing Bar", action: #selector(quit), keyEquivalent: "q")
    }

    // MARK: - Menu builders

    private func buildSourcesMenu() -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let showAll = NSMenuItem(title: "Show all sources",
                                 action: #selector(toggleShowAllSources), keyEquivalent: "")
        showAll.target = self
        showAll.state = prefs.filterEnabled ? .off : .on
        sub.addItem(showAll)
        sub.addItem(.separator())
        for source in prefs.menuSources() {
            let item = NSMenuItem(title: source.name,
                                  action: #selector(toggleSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = source.id
            item.state = prefs.isEnabled(source.id) ? .on : .off
            item.isEnabled = prefs.filterEnabled
            sub.addItem(item)
        }
        return sub
    }

    private func buildDisplayMenu() -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false

        let artist = NSMenuItem(title: "Show artist",
                                action: #selector(toggleShowArtist), keyEquivalent: "")
        artist.target = self
        artist.state = prefs.showArtist ? .on : .off
        sub.addItem(artist)

        let album = NSMenuItem(title: "Show album",
                               action: #selector(toggleShowAlbum), keyEquivalent: "")
        album.target = self
        album.state = prefs.showAlbum ? .on : .off
        sub.addItem(album)

        let hidePaused = NSMenuItem(title: "Hide when paused",
                                    action: #selector(toggleHideWhenPaused), keyEquivalent: "")
        hidePaused.target = self
        hidePaused.state = prefs.hideWhenPaused ? .on : .off
        sub.addItem(hidePaused)

        sub.addItem(.separator())

        let widthItem = NSMenuItem(title: "Width", action: nil, keyEquivalent: "")
        widthItem.submenu = buildWidthMenu()
        sub.addItem(widthItem)

        let speedItem = NSMenuItem(title: "Scroll speed", action: nil, keyEquivalent: "")
        speedItem.submenu = buildChoiceMenu(
            choices: [("Slow", 25), ("Medium", 40), ("Fast", 70)],
            current: Double(prefs.scrollSpeed), action: #selector(setSpeed(_:)))
        sub.addItem(speedItem)

        sub.addItem(.separator())

        let glassItem = NSMenuItem(title: "Liquid Glass", action: nil, keyEquivalent: "")
        let glassMenu = NSMenu.keepOpenChoices(
            [("Regular", 0), ("Clear", 1)], current: prefs.glassClear ? 1 : 0
        ) { [weak self] v in
            guard let self else { return }
            self.prefs.glassClear = v == 1; self.applyGlassPrefs()
        }
        glassMenu.addItem(.separator())
        let fadeView = MenuChoiceView(title: "Clear: translucent cover (85%)")
        fadeView.checked = prefs.clearCoverFade
        fadeView.onSelect = { [weak self, unowned fadeView] in
            guard let self else { return }
            self.prefs.clearCoverFade.toggle()
            fadeView.checked = self.prefs.clearCoverFade
            self.applyGlassPrefs()
        }
        let fadeItem = NSMenuItem()
        fadeItem.view = fadeView
        glassMenu.addItem(fadeItem)
        let noBlurView = MenuChoiceView(title: "Clear: no blur (plain glass)")
        noBlurView.checked = prefs.clearNoBlur
        noBlurView.onSelect = { [weak self, unowned noBlurView] in
            guard let self else { return }
            self.prefs.clearNoBlur.toggle()
            noBlurView.checked = self.prefs.clearNoBlur
            self.applyGlassPrefs()
        }
        let noBlurItem = NSMenuItem()
        noBlurItem.view = noBlurView
        glassMenu.addItem(noBlurItem)
        glassItem.submenu = glassMenu
        sub.addItem(glassItem)

        sub.addItem(.separator())

        let shuffleRepeat = NSMenuItem(title: "Show shuffle & repeat",
                                       action: #selector(toggleShowShuffleRepeat), keyEquivalent: "")
        shuffleRepeat.target = self
        shuffleRepeat.state = prefs.showShuffleRepeat ? .on : .off
        sub.addItem(shuffleRepeat)

        return sub
    }

    // MARK: - Card menu

    private func buildCardMenu() -> NSMenu {
        NSMenu.keepOpenChoices(
            [("On click", 0), ("Always shown", 1), ("Always shown with Lyrics Card", 2)],
            current: prefs.cardMode
        ) { [weak self] v in self?.applyCardMode(v) }
    }

    /// Applies a mode change immediately: card shown/hidden, dismiss monitor
    /// installed/removed, lyrics forced onto the card or released.
    private func applyCardMode(_ mode: Int) {
        let old = prefs.cardMode
        guard mode != old else { return }
        prefs.cardMode = mode
        cardTemporarilyHidden = false

        lyrics?.setForcedCardAttachment(mode == 2)
        monitor.wantsTimeline = lyricsActive
        if mode == 2 {
            syncLyricsTrack(force: true)
            primeLyricsTimeline()
        } else if old == 2, !lyricPrefs.enabled {
            lastSampleKey = nil
            lastSampleDuration = 0
        }

        if mode == 0 {
            // Back to click-to-open: a card that is still up behaves like a
            // manually opened one (dismissed by outside clicks).
            if cardActive { installDismissMonitor() }
        } else {
            removeDismissMonitor()
            content.setHighlighted(false)
            syncAutoCard()
        }
    }

    // MARK: - Lyrics menu (rows keep the menu open, like Liquid Glass)

    private func lyricsChanged() { lyrics?.preferencesDidChange() }

    /// Check-mark row that flips a bool without closing the menu.
    private func lyricToggleItem(_ title: String, get: @escaping () -> Bool,
                                 set: @escaping (Bool) -> Void) -> NSMenuItem {
        let v = MenuChoiceView(title: title)
        v.checked = get()
        v.onSelect = { [weak self, unowned v] in
            set(!get())
            v.checked = get()
            self?.lyricsChanged()
        }
        let item = NSMenuItem()
        item.view = v
        return item
    }

    private func lyricChoiceItem(_ title: String, choices: [(String, Int)], current: Int,
                                 set: @escaping (Int) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = NSMenu.keepOpenChoices(choices, current: current) { [weak self] v in
            set(v)
            self?.lyricsChanged()
        }
        return item
    }

    private func buildLyricsMenu() -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let lp = lyricPrefs

        let forced = prefs.cardMode == 2
        let forcedNote = " (Music Card ▸ Always shown with Lyrics Card)"
        if forced {
            let item = NSMenuItem(title: "Show lyrics" + forcedNote, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.state = .on
            sub.addItem(item)
        } else {
            sub.addItem(lyricToggleItem("Show lyrics", get: { lp.enabled }, set: { [weak self] on in
                guard let self else { return }
                lp.enabled = on
                self.monitor.wantsTimeline = self.lyricsActive
                self.lyrics?.preferencesDidChange()
                if on {
                    self.syncLyricsTrack(force: true)
                    self.primeLyricsTimeline()
                } else {
                    self.lastSampleKey = nil
                    self.lastSampleDuration = 0
                }
            }))
        }
        sub.addItem(lyricChoiceItem("Hide when paused",
            choices: LyricPreferences.pausedHideDelayChoices.map { ($0 >= 60 ? "\(Int($0) / 60)m" : "\(Int($0))s", Int($0)) },
            current: Int(lp.pausedHideDelay)) { lp.pausedHideDelay = TimeInterval($0) })
        sub.addItem(.separator())

        if forced {
            let item = NSMenuItem(title: "Placement" + forcedNote, action: nil, keyEquivalent: "")
            item.isEnabled = false
            sub.addItem(item)
        } else {
            sub.addItem(lyricChoiceItem("Placement",
                choices: [("Floating", 0), ("Below card", 1), ("Below menu bar", 2)],
                current: lp.placement.rawValue) { lp.placement = .init(rawValue: $0) ?? .belowCard })
        }
        sub.addItem(lyricChoiceItem("Context",
            choices: [("Around current line", 0), ("Upcoming only", 1)],
            current: lp.context.rawValue) { lp.context = .init(rawValue: $0) ?? .around })

        let lineChoices = LyricPreferences.lineChoices.map { (String($0), $0) }
        sub.addItem(lyricChoiceItem("Lines", choices: lineChoices, current: lp.lines) { lp.lines = $0 })

        sub.addItem(lyricChoiceItem("Text size",
            choices: [("S", 0), ("M", 1), ("L", 2)],
            current: lp.textSize.rawValue) { lp.textSize = .init(rawValue: $0) ?? .medium })
        sub.addItem(lyricChoiceItem("Floating width (floating only)",
            choices: LyricPreferences.floatingWidthChoices.map { (String(Int($0)), Int($0)) },
            current: Int(lp.floatingWidth)) { lp.floatingWidth = CGFloat($0) })

        sub.addItem(.separator())
        sub.addItem(lyricToggleItem("Lock position (floating only)",
            get: { lp.floatingLocked }, set: { lp.floatingLocked = $0 }))
        sub.addItem(lyricToggleItem("Click-through",
            get: { lp.clickThrough }, set: { lp.clickThrough = $0 }))
        sub.addItem(lyricToggleItem("Blur other lines",
            get: { lp.blurInactive }, set: { lp.blurInactive = $0 }))
        sub.addItem(lyricToggleItem("Click line to seek",
            get: { lp.clickToSeek }, set: { lp.clickToSeek = $0 }))
        sub.addItem(lyricToggleItem("Show translation",
            get: { lp.showTranslation }, set: { lp.showTranslation = $0 }))
        return sub
    }

    private func buildWidthMenu() -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let current = prefs.maxWidth
        var matchedPreset = false
        for preset in Preferences.widthPresets {
            let item = NSMenuItem(title: preset.name,
                                  action: #selector(setWidth(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Double(preset.value)
            let match = abs(preset.value - current) < 0.5
            item.state = match ? .on : .off
            matchedPreset = matchedPreset || match
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let title = matchedPreset ? "Custom…" : "Custom (\(Int(current.rounded())) pt)…"
        let custom = NSMenuItem(title: title,
                                action: #selector(customWidth), keyEquivalent: "")
        custom.target = self
        custom.state = matchedPreset ? .off : .on
        sub.addItem(custom)
        return sub
    }

    private func buildChoiceMenu(choices: [(String, Double)], current: Double,
                                 action: Selector) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        for (label, value) in choices {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(value - current) < 0.5 ? .on : .off
            sub.addItem(item)
        }
        return sub
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector,
                         keyEquivalent: String = "", enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func toggleShowAllSources() { prefs.filterEnabled.toggle(); updateDisplay(); syncLyricsTrack() }
    @objc private func toggleSource(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        prefs.toggleSource(id); updateDisplay(); syncLyricsTrack()
    }
    @objc private func toggleShowArtist()    { prefs.showArtist.toggle();    updateDisplay() }
    @objc private func toggleShowAlbum()     { prefs.showAlbum.toggle();     updateDisplay() }
    @objc private func toggleHideWhenPaused(){ prefs.hideWhenPaused.toggle();updateDisplay() }
    @objc private func toggleShowShuffleRepeat() {
        prefs.showShuffleRepeat.toggle()
        controls.showsShuffleRepeat = prefs.showShuffleRepeat
        resizeCardIfNeeded()
    }

    @objc private func setWidth(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        applyWidth(CGFloat(v))
    }

    /// Saves the width and applies it live. `showTitle` early-returns on
    /// unchanged text, so the status item length must be recomputed here.
    private func applyWidth(_ value: CGFloat) {
        prefs.maxWidth = value
        content.marqueeMaxWidth = prefs.maxWidth
        if isShowing { statusItem.length = content.fittingWidth() }
        statusItemMoved()
    }

    @objc private func customWidth() {
        // Present after menu tracking ends; LSUIElement apps must activate
        // to give the alert focus.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.messageText = "Widget width"
            alert.informativeText = "80–600 pt. Longer titles scroll."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
            let formatter = NumberFormatter()
            formatter.numberStyle = .none
            formatter.allowsFloats = false
            field.formatter = formatter
            field.integerValue = Int(self.prefs.maxWidth.rounded())
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let n = Int(text) else { return }   // non-numeric / empty → ignore
            self.applyWidth(CGFloat(n))                // setter clamps to range
        }
    }

    @objc private func setSpeed(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        prefs.scrollSpeed = CGFloat(v); updateDisplay()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

