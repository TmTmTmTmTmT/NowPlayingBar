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
    private static let playPoint: CGFloat = 16        // play.fill and pause.fill share it
    private static let skipPoint: CGFloat = 10
    private static let modePoint: CGFloat = 12     // shuffle / repeat: plain icon buttons

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
    private let prevButton  = NSButton()
    private let playButton  = NSButton()
    private let nextButton  = NSButton()
    private let shuffleButton = NSButton()
    private let repeatButton  = NSButton()
    /// Glass group holding the transport row; spacing keeps the circles separate.
    private let buttonGroup = NSGlassEffectContainerView()
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
                self.detail = d
            }
        }

        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        for label in [elapsedLabel, remainingLabel] {
            label.font = timeFont
            label.textColor = .secondaryLabelColor  // match artist/album
        }
        remainingLabel.alignment = .right

        // All buttons live in one row inside a glass container (spacing < the
        // gap between circles, so they stay individual).
        [prevButton, playButton, nextButton, shuffleButton, repeatButton]
            .forEach(buttonRow.addSubview)
        buttonGroup.spacing = 6
        buttonGroup.contentView = buttonRow

        [artworkView, titleMarquee, artistMarquee, buttonGroup, scrubBar, elapsedLabel,
         remainingLabel].forEach(container.addSubview)

        view = container
    }

    private func configure(_ button: NSButton, symbol: String, point: CGFloat, action: Selector) {
        button.image = Self.symbolImage(symbol, point: point)
        if button === shuffleButton || button === repeatButton {
            button.isBordered = false      // plain icon button, no glass circle
        } else {
            button.bezelStyle = .glass
            button.borderShape = .circle
            button.controlSize = .large
        }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone   // glyph keeps its natural size; the frame sizes the circle
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
        artworkView.frame = NSRect(x: pad, y: pad, width: art, height: art)

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

        // Transport row, anchored a fixed gap above the scrubber frame (the gap
        // above, to the artist line, is the remainder: 5pt at the current sizes,
        // keep >= 4). Frames are circles (glass follows the frame); diameters are
        // even and cy is whole, so origins land on whole points.
        let bandBottom = scrubBar.frame.maxY
        let playD: CGFloat = 38, skipD: CGFloat = 34, modeD: CGFloat = 28
        let gapBelow: CGFloat = 8
        let cy = (bandBottom + gapBelow + playD / 2).rounded()
        let wide = showsShuffleRepeat
        let skipOff: CGFloat = wide ? 42 : 50
        // The row spans the transport band; buttons are laid out in its
        // coordinates (row origin and size are whole points).
        let rowH: CGFloat = playD
        buttonGroup.frame = NSRect(x: rx, y: cy - rowH / 2, width: rw, height: rowH)
        buttonRow.frame = buttonGroup.bounds
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
            overlay.cornerCurve = .continuous
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
