import AppKit

/// The "Now Playing" control card shown on left-click: a full-height album
/// artwork on the left, with title, artist, transport buttons, scrubber and
/// elapsed / remaining time stacked in a column on the right.
///
/// Hosted inside a borderless glass `NSPanel` (no popover arrow). Playback
/// position is interpolated locally between fetches (`NowPlayingDetail
/// .position(at:)`); a light 0.5 s ticker runs only while the card is visible.
final class NowPlayingPopoverController: NSViewController {

    /// Wider when the shuffle / repeat buttons are shown. Height is fixed.
    var cardSize: NSSize { NSSize(width: showsShuffleRepeat ? 360 : 320, height: 150) }

    /// Shows the shuffle / repeat buttons flanking the transport row. The panel
    /// is rebuilt by the owner when `cardSize` changes (glass mask is fixed).
    var showsShuffleRepeat = false {
        didSet {
            guard isViewLoaded else { return }
            shuffleButton.isHidden = !showsShuffleRepeat
            repeatButton.isHidden = !showsShuffleRepeat
            if !showsShuffleRepeat {
                modes = nil
                updateModeButtons()
            } else if ticker != nil {
                fetchModes()
            }
            view.needsLayout = true
        }
    }

    private let monitor: NowPlayingMonitor

    private var detail: NowPlayingDetail?
    private var ticker: Timer?
    /// Identity of the currently shown track, to detect track changes (vs.
    /// play/pause toggles or progress refreshes) and animate only those.
    private var lastTrackKey: String?
    /// Track key whose artwork is currently displayed. Artwork arrives ~300ms
    /// after the title on a track change, so it's applied separately once a
    /// non-nil image for the new track shows up (see the delayed re-fetch).
    private var shownArtworkKey: String?
    /// Bounded self-poll to fetch the current track's artwork once it's ready
    /// (it lags the title, and back-to-back skips can delay it further).
    private var artworkRetryCount = 0
    private let maxArtworkRetries = 24
    /// Source's shuffle / repeat state (Music only); nil = unknown.
    private var modes: PlaybackModes?
    private var modesFetchInFlight = false
    /// Set when automation permission was denied: stops periodic fetches until
    /// the panel is reopened (one retry per open).
    private var modesDenied = false
    /// Ticks since the last periodic modes fetch (0.5 s per tick).
    private var modesTickCount = 0
    private let modesFetchTicks = 6   // ~3 s

    // MARK: UI
    private let artworkView   = ClickableImageView()
    private let titleMarquee  = MarqueeView(frame: .zero)
    private let artistMarquee = MarqueeView(frame: .zero)
    private let prevButton  = HoverButton()
    private let playButton  = HoverButton()
    private let nextButton  = HoverButton()
    private let shuffleButton = HoverButton()
    private let repeatButton  = HoverButton()
    private let scrubBar    = ScrubBar()
    private let elapsedLabel   = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "-0:00")

    init(monitor: NowPlayingMonitor) {
        self.monitor = monitor
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View

    override func loadView() {
        let container = LayoutView(frame: NSRect(origin: .zero, size: cardSize))
        container.onLayout = { [weak self] in self?.relayout() }

        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 8
        artworkView.layer?.masksToBounds = true
        artworkView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        // Click the artwork to launch / focus the source app.
        artworkView.onClick = { [weak self] in self?.openSourceApp() }

        // Title + artist scroll (marquee) when wider than their column.
        titleMarquee.font = .systemFont(ofSize: 13, weight: .bold)
        titleMarquee.baseColor = .white                                   // fixed: card is always dark glass
        titleMarquee.pointsPerSecond = 30
        artistMarquee.font = .systemFont(ofSize: 11.5, weight: .regular)
        artistMarquee.baseColor = NSColor.white.withAlphaComponent(0.78)  // brighter than secondary
        artistMarquee.pointsPerSecond = 30

        configure(prevButton, symbol: "backward.fill", point: 16, action: #selector(previous))
        configure(playButton, symbol: "pause.fill",    point: 24, action: #selector(togglePlay))
        configure(nextButton, symbol: "forward.fill",  point: 16, action: #selector(next))
        configure(shuffleButton, symbol: "shuffle", point: 12, action: #selector(toggleShuffle))
        configure(repeatButton,  symbol: "repeat",  point: 12, action: #selector(toggleRepeat))
        shuffleButton.toolTip = "Toggle shuffle"
        repeatButton.toolTip = "Toggle repeat"
        shuffleButton.isHidden = !showsShuffleRepeat
        repeatButton.isHidden = !showsShuffleRepeat

        // Live label update while dragging.
        scrubBar.onSeekPreview = { [weak self] seconds in
            guard let self else { return }
            self.elapsedLabel.stringValue = Self.timeString(seconds)
            if let d = self.detail {
                self.remainingLabel.stringValue = "-" + Self.timeString(max(d.duration - seconds, 0))
            }
        }
        // Commit the seek on release.
        scrubBar.onSeekCommit = { [weak self] seconds in
            guard let self else { return }
            self.monitor.seek(to: seconds)
            if var d = self.detail {                 // optimistic local update
                d.elapsedTime = seconds
                d.sampledAt = Date()
                self.detail = d
            }
        }

        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        for label in [elapsedLabel, remainingLabel] {
            label.font = timeFont
            label.textColor = NSColor.white.withAlphaComponent(0.78)  // match artist/album
        }
        remainingLabel.alignment = .right

        [artworkView, titleMarquee, artistMarquee, prevButton, playButton,
         nextButton, shuffleButton, repeatButton, scrubBar, elapsedLabel,
         remainingLabel].forEach(container.addSubview)

        view = container
    }

    private func configure(_ button: HoverButton, symbol: String, point: CGFloat, action: Selector) {
        let cfg = NSImage.SymbolConfiguration(pointSize: point, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imageScaling = .scaleNone   // glyph keeps its natural size; the frame only sizes the circle
        button.target = self
        button.action = action
        // The circle itself is the hover region (no inset), so neighbouring
        // buttons never highlight together.
        button.hoverInset = 0
        button.applyIdle()
    }

    // MARK: - Layout (explicit frames; card size is fixed)

    private func relayout() {
        let pad: CGFloat = 14
        let w = view.bounds.width
        let h = view.bounds.height

        // Full-height square artwork on the left.
        let art = h - pad * 2
        artworkView.frame = NSRect(x: pad, y: pad, width: art, height: art)

        // Right column.
        let rx = pad + art + 16
        let rw = w - rx - pad
        let cx = rx + rw / 2

        let titleH: CGFloat = 20
        titleMarquee.frame  = NSRect(x: rx, y: h - pad - titleH, width: rw, height: titleH)
        artistMarquee.frame = NSRect(x: rx, y: h - pad - titleH - 2 - 16, width: rw, height: 16)

        // Time labels at the bottom, scrubber just above them.
        elapsedLabel.frame   = NSRect(x: rx, y: pad, width: 64, height: 13)
        remainingLabel.frame = NSRect(x: rx + rw - 64, y: pad, width: 64, height: 13)
        let scrubY = pad + 13 + 4
        scrubBar.frame = NSRect(x: rx, y: scrubY, width: rw, height: 16)

        // Transport row, centered between the artist line and the scrubber,
        // nudged down a few points. Frames are circles (diameter = highlight);
        // cy is floored and diameters are even so origins land on whole points.
        let bandTop = artistMarquee.frame.minY
        let bandBottom = scrubBar.frame.maxY
        let cy = ((bandTop + bandBottom) / 2 - 5).rounded(.down)
        let wide = showsShuffleRepeat
        let playD: CGFloat = 38, skipD: CGFloat = 34, modeD: CGFloat = 28
        let skipOff: CGFloat = wide ? 42 : 50
        func circle(_ b: HoverButton, _ dx: CGFloat, _ d: CGFloat) {
            b.frame = NSRect(x: cx + dx - d / 2, y: cy - d / 2, width: d, height: d)
        }
        circle(playButton, 0, playD)
        circle(prevButton, -skipOff, skipD)
        circle(nextButton, skipOff, skipD)
        circle(shuffleButton, -80, modeD)
        circle(repeatButton, 80, modeD)
    }

    // MARK: - Data

    private func trackKey(_ d: NowPlayingDetail) -> String {
        [d.title, d.artist ?? "", d.album ?? ""].joined(separator: "\u{1}")
    }

    private func artistText(_ d: NowPlayingDetail) -> String {
        [d.artist, d.album].compactMap { $0 }.joined(separator: " — ")
    }

    /// Apply a fresh snapshot. On a track change the title/artist crossfade and
    /// the artwork cross-dissolves; play/pause toggles and progress refreshes
    /// update instantly (no flashing).
    func apply(_ d: NowPlayingDetail) {
        _ = view   // force loadView() if needed
        let key = trackKey(d)
        let isTrackChange = (lastTrackKey != nil && key != lastTrackKey)
        if isTrackChange { artworkRetryCount = 0 }   // fresh budget per track
        lastTrackKey = key
        detail = d
        if isTrackChange { fetchModes() }

        // Title + artist.
        if isTrackChange {
            animateTextChange(to: d)
        } else {
            titleMarquee.setText(d.title)
            artistMarquee.setText(artistText(d))
        }

        // Artwork: apply only when present (a track change reports nil art for
        // ~300ms — never blank the view) and only once per track. Crossfade
        // unless this is the first artwork shown since the panel opened.
        if let art = d.artwork, key != shownArtworkKey {
            setArtwork(art, animated: shownArtworkKey != nil)
            shownArtworkKey = key
        }

        setPlayIcon(isPlaying: d.isPlaying)
        scrubBar.duration = max(d.duration, 1)
        refreshProgress()

        reconcileArtwork()   // keep polling until the current track's art shows
    }

    /// If the displayed artwork doesn't match the current track yet (it arrives
    /// ~300ms+ after the title), re-fetch shortly. Stops as soon as it matches
    /// or the retry budget is spent. `ticker` is the panel-visible proxy.
    private func reconcileArtwork() {
        guard ticker != nil else { return }
        guard shownArtworkKey != lastTrackKey else { artworkRetryCount = 0; return }
        guard artworkRetryCount < maxArtworkRetries else { return }
        artworkRetryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.ticker != nil else { return }
            self.monitor.fetchDetail { [weak self] d in
                guard let self, let d, self.ticker != nil else { return }
                self.apply(d)
            }
        }
    }

    private func animateTextChange(to d: NowPlayingDetail) {
        let half = 0.184
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = half
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            titleMarquee.animator().alphaValue = 0
            artistMarquee.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.titleMarquee.setText(d.title)
            self.artistMarquee.setText(self.artistText(d))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = half
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.titleMarquee.animator().alphaValue = 1
                self.artistMarquee.animator().alphaValue = 1
            }
        })
    }

    /// Sets the artwork, optionally cross-dissolving from the old image. The new
    /// image is set directly (always updates); the OLD image is snapshotted into
    /// an overlay layer that fades out — a CATransition keyed on "contents" does
    /// not reliably animate NSImageView.
    private func setArtwork(_ image: NSImage, animated: Bool) {
        if animated,
           let host = artworkView.layer,
           let old = artworkView.image,
           let cg = old.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let overlay = CALayer()
            overlay.frame = artworkView.bounds
            overlay.contents = cg
            overlay.contentsGravity = .resizeAspect
            overlay.cornerRadius = host.cornerRadius
            overlay.masksToBounds = true
            host.addSublayer(overlay)

            artworkView.image = image   // new image shows underneath at once

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.1
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.isRemovedOnCompletion = false
            fade.fillMode = .forwards
            CATransaction.begin()
            CATransaction.setCompletionBlock { overlay.removeFromSuperlayer() }
            overlay.add(fade, forKey: "fade")
            CATransaction.commit()
        } else {
            artworkView.image = image
        }
    }

    private func setPlayIcon(isPlaying: Bool) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        playButton.image = NSImage(systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    private func refreshProgress() {
        guard let d = detail, !scrubBar.isDragging else { return }
        let pos = d.position(at: Date())
        scrubBar.position = pos
        elapsedLabel.stringValue   = Self.timeString(pos)
        remainingLabel.stringValue = "-" + Self.timeString(max(d.duration - pos, 0))
    }

    // MARK: - Ticker (driven by the panel's show/hide)

    func startTicking() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshProgress()
            self.modesTickCount += 1
            if self.modesTickCount >= self.modesFetchTicks {
                self.modesTickCount = 0
                if !self.modesDenied { self.fetchModes() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        refreshProgress()
        modesDenied = false      // one retry per open
        modesTickCount = 0
        fetchModes()
    }

    func stopTicking() {
        ticker?.invalidate()
        ticker = nil
        // Reset so the next open shows instantly; crossfades are for live
        // track changes while the panel is visible.
        lastTrackKey = nil
        shownArtworkKey = nil
        artworkRetryCount = 0
        modesFetchInFlight = false
        modesTickCount = 0
        modes = nil
        updateModeButtons()
        titleMarquee.alphaValue = 1
        artistMarquee.alphaValue = 1
    }

    // MARK: - Actions

    @objc private func previous() { monitor.send(command: 5) }
    @objc private func next()     { monitor.send(command: 4) }
    @objc private func togglePlay() {
        monitor.send(command: 2)
        if var d = detail {                       // optimistic, instant feedback
            d.elapsedTime = d.position(at: Date())
            d.sampledAt = Date()
            d.isPlaying.toggle()
            apply(d)
        }
    }

    /// Sends the toggle command, flashes the button, and (if the state is known)
    /// predicts the next state at once; a re-read 0.4 s later confirms it.
    @objc private func toggleShuffle() {
        monitor.send(command: 6)
        shuffleButton.flash()
        if var m = modes {
            m.shuffle.toggle()
            modes = m
            updateModeButtons()
        }
        scheduleModesConfirm()
    }

    @objc private func toggleRepeat() {
        monitor.send(command: 7)
        repeatButton.flash()
        if var m = modes {
            m.repeatMode = m.repeatMode.next
            modes = m
            updateModeButtons()
        }
        scheduleModesConfirm()
    }

    // MARK: - Shuffle / repeat state

    private func scheduleModesConfirm() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.fetchModes()
        }
    }

    /// Reads the source's shuffle / repeat state. Never runs when the option is
    /// off or the panel is hidden (`ticker` is the visible proxy).
    private func fetchModes() {
        guard showsShuffleRepeat, ticker != nil, !modesFetchInFlight,
              let id = detail?.sourceBundleID else { return }
        modesFetchInFlight = true
        monitor.fetchModes(for: id) { [weak self] result in
            guard let self else { return }
            self.modesFetchInFlight = false
            guard self.ticker != nil else { return }   // panel hidden meanwhile
            switch result {
            case .modes(let m):
                self.modes = m
            case .unsupported, .failed:
                self.modes = nil
            case .denied:
                self.modes = nil
                self.modesDenied = true
            }
            self.updateModeButtons()
        }
    }

    private func updateModeButtons() {
        guard isViewLoaded else { return }
        shuffleButton.isActive = modes?.shuffle == true
        let rep = modes?.repeatMode ?? .off
        let symbol = rep == .one ? "repeat.1" : "repeat"
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        repeatButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        repeatButton.isActive = rep != .off
    }

    /// Launches the source app if not running, or brings it to the front.
    private func openSourceApp() {
        guard let id = detail?.sourceBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
    }

    // MARK: - Helpers

    private static func timeString(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Plain container whose `layout()` forwards to a closure — lets the controller
/// own the frame math while AppKit drives when it runs.
private final class LayoutView: NSView {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}

/// An image view that acts like a button: pointing-hand cursor, a brief press
/// dim, and an `onClick` fired on mouse-up inside its bounds.
final class ClickableImageView: NSImageView {
    var onClick: (() -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        animator().alphaValue = 0.75
    }

    override func mouseUp(with event: NSEvent) {
        animator().alphaValue = 1
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { onClick?() }
    }
}

/// A borderless transport button that "activates" on hover: the glyph brightens
/// and a soft rounded highlight fades in behind it. The hover region can be
/// expanded past the bounds via `hoverInset` so it triggers as the pointer nears.
final class HoverButton: NSButton {
    var hoverInset: CGFloat = 0          // negative = larger-than-bounds hover area
    private var tracking: NSTrackingArea?
    private var hovered = false
    /// Marks a toggle as "on": blue glyph, kept while hovering (the hover
    /// background circle still shows).
    var isActive = false { didSet { updateTint() } }
    // Fixed white, NOT labelColor: the dark glass card must keep white glyphs
    // even when the panel floats over bright content (dynamic colors can
    // resolve dark there and the buttons vanish).
    private let idleTint  = NSColor.white.withAlphaComponent(0.85)
    private let hoverTint = NSColor.white

    private func updateTint() {
        contentTintColor = isActive ? .systemBlue : (hovered ? hoverTint : idleTint)
    }

    /// Set the resting (un-hovered) appearance.
    func applyIdle() {
        wantsLayer = true
        // No masksToBounds: cornerRadius still rounds the background, but the
        // glyph must not be clipped by the circle.
        updateTint()
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let area = bounds.insetBy(dx: hoverInset, dy: hoverInset)
        let t = NSTrackingArea(rect: area,
                               options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.cornerRadius = min(newSize.width, newSize.height) / 2
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent)  { setHovered(false) }

    /// Click feedback: the highlight circle flashes brighter, then eases back
    /// to its hover value (still inside) or clear.
    func flash() {
        guard let layer else { return }
        layer.removeAnimation(forKey: "flash")
        let rest = (hovered ? NSColor.white.withAlphaComponent(0.16) : NSColor.clear).cgColor
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.fromValue = NSColor.white.withAlphaComponent(0.32).cgColor
        anim.toValue = rest
        anim.duration = 0.2
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.backgroundColor = rest
        layer.add(anim, forKey: "flash")
    }

    private func setHovered(_ on: Bool) {
        hovered = on
        updateTint()
        layer?.removeAnimation(forKey: "flash")
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.138)
        layer?.backgroundColor = on
            ? NSColor.white.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
        CATransaction.commit()
    }
}

/// A custom scrubber: a slim progress bar with no knob at rest. On hover the
/// bar turns white and a draggable knob fades in. Click or drag to seek.
final class ScrubBar: NSView {
    var duration: Double = 1 { didSet { needsDisplay = true } }
    var position: Double = 0 {
        didSet { if !isDragging { needsDisplay = true } }
    }

    /// Called continuously while dragging (to update time labels).
    var onSeekPreview: ((Double) -> Void)?
    /// Called once on mouse-up (to commit the seek).
    var onSeekCommit: ((Double) -> Void)?

    private(set) var isDragging = false
    private var hovered = false
    private var tracking: NSTrackingArea?

    private let hInset: CGFloat = 6          // keeps the knob inside the bounds
    private let knobDiameter: CGFloat = 11

    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true;  needsDisplay = true }
    override func mouseExited(with event: NSEvent)  { hovered = false; needsDisplay = true }

    // MARK: Interaction

    private func fraction(at point: NSPoint) -> Double {
        let usable = bounds.width - hInset * 2
        guard usable > 0 else { return 0 }
        return min(max((point.x - hInset) / usable, 0), 1)
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        seekPreview(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        seekPreview(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        let f = fraction(at: convert(event.locationInWindow, from: nil))
        position = f * duration
        isDragging = false
        onSeekCommit?(position)
        needsDisplay = true
    }

    private func seekPreview(with event: NSEvent) {
        let f = fraction(at: convert(event.locationInWindow, from: nil))
        position = f * duration
        onSeekPreview?(position)
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let trackH: CGFloat = hovered ? 5 : 3
        let y = (bounds.height - trackH) / 2
        let x0 = hInset
        let usable = bounds.width - hInset * 2
        let frac = duration > 0 ? CGFloat(min(max(position / duration, 0), 1)) : 0
        let fillW = usable * frac

        let bgColor   = NSColor.white.withAlphaComponent(0.22)
        let fillColor = hovered ? NSColor.white : NSColor.systemBlue

        // Background track (capsule).
        let bg = NSBezierPath(roundedRect: NSRect(x: x0, y: y, width: usable, height: trackH),
                              xRadius: trackH / 2, yRadius: trackH / 2)
        bgColor.setFill(); bg.fill()

        // Filled portion.
        if fillW > 0 {
            let fill = NSBezierPath(roundedRect: NSRect(x: x0, y: y, width: fillW, height: trackH),
                                    xRadius: trackH / 2, yRadius: trackH / 2)
            fillColor.setFill(); fill.fill()
        }

        // Knob — only on hover.
        if hovered {
            let cx = x0 + fillW
            let cy = bounds.height / 2
            let knob = NSBezierPath(ovalIn: NSRect(x: cx - knobDiameter / 2,
                                                   y: cy - knobDiameter / 2,
                                                   width: knobDiameter, height: knobDiameter))
            NSColor.white.setFill(); knob.fill()
        }
    }
}
