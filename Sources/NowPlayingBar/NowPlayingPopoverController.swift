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

    /// Single source of truth for transport symbol sizes (semibold, monochrome).
    private static let playPoint: CGFloat = 20        // play.fill and pause.fill share it
    private static let skipPoint: CGFloat = 14
    private static let modePoint: CGFloat = 12     // shuffle / repeat: plain icon buttons (all five are borderless)

    private static func symbolImage(_ name: String, point: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: point, weight: .semibold))
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
    /// Pending confirm re-fetch (cancellable; at most one). See `scheduleConfirm`.
    private var confirmItem: DispatchWorkItem?
    /// Duration of each leg (out / in) of a track change. Shared with the menu
    /// bar title so text and artwork transitions run in step.
    static let transitionLeg: TimeInterval = 0.25
    /// Called once per `beginTrackTransition` when the new track's text and
    /// artwork are both in hand; the owner then calls `finishTrackTransition`.
    var onTransitionReady: (() -> Void)?
    /// True between `beginTrackTransition` and `finishTrackTransition`: visible
    /// text / artwork stay frozen (text faded out) while new data is only stored.
    private var transitionPending = false
    private var transitionOldKey: String?      // track key shown when the transition began
    private var pendingKey: String?            // newest track key seen while pending
    private var pendingTitle: String?
    private var pendingArtist: String?
    private var pendingArtwork: NSImage?
    private var transitionReadyFired = false
    /// Set when automation permission was denied: stops periodic fetches until
    /// the panel is reopened (one retry per open).
    private var modesDenied = false
    /// Ticks since the last periodic modes fetch (0.5 s per tick).
    private var modesTickCount = 0
    private let modesFetchTicks = 6   // ~3 s

    // MARK: UI
    private let artworkView   = ClickableImageView()
    private let artworkGlass  = NSGlassEffectView()   // TEST: Liquid Glass wrapper around the artwork
    /// Cover opacity (1 = opaque); lowered for the Clear glass look.
    var artworkAlpha: CGFloat = 1 {
        didSet { artworkGlass.alphaValue = artworkAlpha }
    }
    private let titleMarquee  = MarqueeView(frame: .zero)
    private let artistMarquee = MarqueeView(frame: .zero)
    private let prevButton  = HighlightButton()
    private let playButton  = HighlightButton()
    private let nextButton  = HighlightButton()
    private let shuffleButton = HighlightButton()
    private let repeatButton  = HighlightButton()
    /// Holds all five buttons, placed directly in the card (no glass).
    private let buttonRow   = NSView()
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
        artworkView.layer?.cornerRadius = 8       // concentric with the card: 22 - 14 padding
        artworkView.layer?.cornerCurve = .continuous
        artworkView.layer?.masksToBounds = true
        artworkView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        // Click the artwork to launch / focus the source app.
        artworkView.onClick = { [weak self] in self?.openSourceApp() }
        artworkGlass.cornerRadius = 8
        artworkGlass.contentView = artworkView

        // Title + artist scroll (marquee) when wider than their column.
        titleMarquee.font = .systemFont(ofSize: 13, weight: .bold)
        titleMarquee.baseColor = .labelColor
        titleMarquee.pointsPerSecond = 30
        artistMarquee.font = .systemFont(ofSize: 11.5, weight: .regular)
        artistMarquee.baseColor = .secondaryLabelColor
        artistMarquee.pointsPerSecond = 30

        configure(prevButton, symbol: "backward.fill", point: Self.skipPoint, action: #selector(previous))
        configure(playButton, symbol: "pause.fill",    point: Self.playPoint, action: #selector(togglePlay))
        configure(nextButton, symbol: "forward.fill",  point: Self.skipPoint, action: #selector(next))
        configure(shuffleButton, symbol: "shuffle", point: Self.modePoint, action: #selector(toggleShuffle))
        configure(repeatButton,  symbol: "repeat",  point: Self.modePoint, action: #selector(toggleRepeat))
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
                d.isSettled = false                  // confirmed by a re-fetch
                self.detail = d
                self.scheduleConfirm(attempt: 0)
            }
        }

        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        for label in [elapsedLabel, remainingLabel] {
            label.font = timeFont
            label.textColor = .secondaryLabelColor  // match artist/album
        }
        remainingLabel.alignment = .right

        // All buttons live in one plain row view.
        [prevButton, playButton, nextButton, shuffleButton, repeatButton]
            .forEach(buttonRow.addSubview)

        [artworkGlass, titleMarquee, artistMarquee, buttonRow, scrubBar, elapsedLabel,
         remainingLabel].forEach(container.addSubview)

        view = container
    }

    private func configure(_ button: NSButton, symbol: String, point: CGFloat, action: Selector) {
        button.image = Self.symbolImage(symbol, point: point)
        button.isBordered = false          // plain icon button, no glass circle
        if button !== shuffleButton && button !== repeatButton {
            button.contentTintColor = .labelColor   // shuffle / repeat: see setActive
        }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone   // glyph keeps its natural size; the frame is only the click area
        button.target = self
        button.action = action
    }

    /// Shuffle / repeat "on" look: accent icon color (off = secondary label).
    private func setActive(_ button: NSButton, _ on: Bool) {
        button.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
    }

    // MARK: - Layout (explicit frames; card size is fixed)

    private func relayout() {
        let pad: CGFloat = 14
        let w = view.bounds.width
        let h = view.bounds.height

        // Full-height square artwork on the left.
        let art = h - pad * 2
        artworkGlass.frame = NSRect(x: pad, y: pad, width: art, height: art)

        // Right column.
        let rx = pad + art + 16
        let rw = w - rx - pad

        let titleH: CGFloat = 20
        titleMarquee.frame  = NSRect(x: rx, y: h - pad - titleH, width: rw, height: titleH)
        artistMarquee.frame = NSRect(x: rx, y: h - pad - titleH - 2 - 16, width: rw, height: 16)

        // Time labels at the bottom, scrubber just above them.
        elapsedLabel.frame   = NSRect(x: rx, y: pad, width: 64, height: 13)
        remainingLabel.frame = NSRect(x: rx + rw - 64, y: pad, width: 64, height: 13)
        let scrubY = pad + 13 + 4
        scrubBar.frame = NSRect(x: rx, y: scrubY, width: rw, height: 16)

        // Transport row. No circles are drawn, so the frames are just click
        // areas; the row is centered on the play icon. cy balances the visible
        // gaps (local coords, y up): artist text bottom ~99, scrubber track top
        // ~41 (slider frame 31...47, track centered), play icon visible height
        // ~1.04 * playPoint ~= 21. Equal gaps -> cy = (99 + 41) / 2 = 70
        // (icon spans ~59.6...80.4: 18.6 above to the text, 18.6 below to the track).
        let playD: CGFloat = 38, skipD: CGFloat = 34, modeD: CGFloat = 28
        let cy: CGFloat = 70
        let wide = showsShuffleRepeat
        let skipOff: CGFloat = wide ? 42 : 50
        // The row spans the transport band; buttons are laid out in its
        // coordinates (row origin and size are whole points).
        let rowH: CGFloat = playD
        buttonRow.frame = NSRect(x: rx, y: cy - rowH / 2, width: rw, height: rowH)
        func circle(_ b: NSButton, _ dx: CGFloat, _ d: CGFloat) {
            b.frame = NSRect(x: rw / 2 + dx - d / 2, y: rowH / 2 - d / 2, width: d, height: d)
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
    func apply(_ d: NowPlayingDetail) { apply(d, confirmAttempt: nil) }

    /// `confirmAttempt` is set when the snapshot comes from a confirm re-fetch.
    private func apply(_ d: NowPlayingDetail, confirmAttempt: Int?) {
        _ = view   // force loadView() if needed
        let key = trackKey(d)
        let isTrackChange = (lastTrackKey != nil && key != lastTrackKey)
        if isTrackChange { artworkRetryCount = 0 }   // fresh budget per track
        let previous = detail
        lastTrackKey = key
        detail = d
        if isTrackChange {
            cancelConfirm()   // track changes use the transition / artwork flow
        } else if ticker != nil, let prev = previous {
            // Same track: confirm unsettled snapshots and play / pause flips.
            let flipped = prev.isPlaying != d.isPlaying
            if !flipped && d.isSettled {
                cancelConfirm()                                  // settled: chain ends
            } else if flipped || confirmAttempt == nil {
                scheduleConfirm(attempt: 0)                      // new change: 0.4 s
            } else if let n = confirmAttempt, n < 1 {
                scheduleConfirm(attempt: n + 1)                  // still unsettled: 1.2 s
            } else {
                cancelConfirm()                                  // budget spent
            }
        }
        if isTrackChange { fetchModes() }

        if transitionPending {
            // Frozen: visible text / artwork change only in finishTrackTransition.
            // The newest track wins; text + artwork must both be stored first.
            if key != transitionOldKey {
                pendingKey = key
                pendingTitle = d.title
                pendingArtist = artistText(d)
                if let art = d.artwork { pendingArtwork = art }
                if !transitionReadyFired, pendingArtwork != nil {
                    transitionReadyFired = true
                    onTransitionReady?()
                }
            }
            setPlayIcon(isPlaying: d.isPlaying)
            scrubBar.duration = max(d.duration, 1)
            refreshProgress()
            reconcileArtwork()
            return
        }

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

    /// Re-fetches the detail at 0.4 s (attempt 0) or 1.2 s after the change
    /// (attempt 1, 0.8 s after the first). A new schedule replaces any pending one.
    private func scheduleConfirm(attempt: Int) {
        confirmItem?.cancel()
        guard ticker != nil else { confirmItem = nil; return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.ticker != nil else { return }
            self.confirmItem = nil
            self.monitor.fetchDetail { [weak self] d in
                guard let self, let d, self.ticker != nil else { return }
                self.apply(d, confirmAttempt: attempt)
            }
        }
        confirmItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.4 : 0.8), execute: item)
    }

    private func cancelConfirm() {
        confirmItem?.cancel()
        confirmItem = nil
    }

    /// If the displayed artwork doesn't match the current track yet (it arrives
    /// ~300ms+ after the title), re-fetch shortly. Stops as soon as it matches
    /// or the retry budget is spent. `ticker` is the panel-visible proxy.
    private func reconcileArtwork() {
        guard ticker != nil else { return }
        guard shownArtworkKey != lastTrackKey else { artworkRetryCount = 0; return }
        if transitionPending, pendingArtwork != nil { return }   // arrived; waits for finish
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

    // MARK: - Track transition (driven by the owner; see AppDelegate)

    /// Starts the "out" leg: title + artist fade out and stay hidden until
    /// `finishTrackTransition`. Calling again (quick skips) restarts the wait;
    /// the last track seen wins.
    func beginTrackTransition() {
        _ = view
        transitionPending = true
        transitionOldKey = lastTrackKey
        pendingKey = nil
        pendingTitle = nil
        pendingArtist = nil
        pendingArtwork = nil
        transitionReadyFired = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.transitionLeg
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            titleMarquee.animator().alphaValue = 0
            artistMarquee.animator().alphaValue = 0
        }
    }

    /// Runs the "in" leg: new text fades in and the artwork cross-dissolves at
    /// the same moment, both over `transitionLeg`. If the artwork is not here
    /// yet (timeout), only the text goes in; the artwork follows via the normal
    /// polling path with the same duration.
    func finishTrackTransition() {
        guard transitionPending else { return }
        transitionPending = false
        if let t = pendingTitle, let a = pendingArtist {
            titleMarquee.setText(t)
            artistMarquee.setText(a)
        }   // else: nothing new arrived; fade the unchanged text back in
        if let art = pendingArtwork, let k = pendingKey {
            setArtwork(art, animated: shownArtworkKey != nil)
            shownArtworkKey = k
        }
        clearPending()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.transitionLeg
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            titleMarquee.animator().alphaValue = 1
            artistMarquee.animator().alphaValue = 1
        }
        reconcileArtwork()
    }

    private func clearPending() {
        transitionOldKey = nil
        pendingKey = nil
        pendingTitle = nil
        pendingArtist = nil
        pendingArtwork = nil
        transitionReadyFired = false
    }

    /// Fallback when a track change arrives without `beginTrackTransition`.
    private func animateTextChange(to d: NowPlayingDetail) {
        let half = Self.transitionLeg
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
            overlay.cornerCurve = .continuous
            overlay.masksToBounds = true
            host.addSublayer(overlay)

            artworkView.image = image   // new image shows underneath at once

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = Self.transitionLeg
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
        playButton.image = Self.symbolImage(isPlaying ? "pause.fill" : "play.fill",
                                            point: Self.playPoint)
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
        cancelConfirm()
        [prevButton, playButton, nextButton, shuffleButton, repeatButton].forEach { $0.resetState() }
        // Reset so the next open shows instantly; crossfades are for live
        // track changes while the panel is visible.
        lastTrackKey = nil
        shownArtworkKey = nil
        artworkRetryCount = 0
        modesFetchInFlight = false
        modesTickCount = 0
        modes = nil
        updateModeButtons()
        transitionPending = false
        clearPending()
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
            d.isSettled = false                   // confirmed by a re-fetch (apply schedules it)
            apply(d)
        }
    }

    /// Sends the toggle command and (if the state is known)
    /// predicts the next state at once; a re-read 0.4 s later confirms it.
    @objc private func toggleShuffle() {
        monitor.send(command: 6)
        if var m = modes {
            m.shuffle.toggle()
            modes = m
            updateModeButtons()
        }
        scheduleModesConfirm()
    }

    @objc private func toggleRepeat() {
        monitor.send(command: 7)
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
        setActive(shuffleButton, modes?.shuffle == true)
        let rep = modes?.repeatMode ?? .off
        let symbol = rep == .one ? "repeat.1" : "repeat"
        repeatButton.image = Self.symbolImage(symbol, point: Self.modePoint)
        setActive(repeatButton, rep != .off)
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
