import AppKit

/// Borderless panel that can become key without activating the app — glass
/// buttons render dimmed in a non-key window.
final class CardPanel: NSPanel {
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
    private var controls: NowPlayingPopoverController!
    private var dismissMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var panelIsShown: Bool { panel?.isVisible ?? false }

    /// Fade-in target (the glass has its own translucency).
    private let panelAlpha: CGFloat = 1.0

    private var current: NowPlayingInfo?

    /// Tracks whether the title is currently visible (or animating in).
    /// Guards against redundant show/hide calls.
    private var isShowing = false

    /// The title string currently on screen. Lets us skip a crossfade when
    /// the displayed text didn't actually change (e.g. play/pause toggle).
    private var displayedTitle: String?

    private let fadeDuration: TimeInterval = 0.437  // show / hide
    private let swapDuration: TimeInterval = 0.299  // each leg of track-change crossfade

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

        guard monitor.adapterExists else { return }

        monitor.onUpdate = { [weak self] info in self?.handleUpdate(info) }
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
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
    }

    // MARK: - Click routing

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRight {
            if panelIsShown { hidePanel() }
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
        panelIsShown ? hidePanel() : showPanel()
    }

    private func showPanel() {
        guard let button = statusItem.button, let bwin = button.window else { return }
        monitor.fetchDetail { [weak self] detail in
            guard let self, let detail else { return }
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
            let btn = bwin.convertToScreen(button.convert(button.bounds, to: nil))
            var x = btn.midX - size.width / 2
            let y = btn.minY - size.height - 15
            if let scr = bwin.screen ?? NSScreen.main {
                x = min(max(x, scr.frame.minX + 8), scr.frame.maxX - size.width - 8)
            }
            panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height),
                           display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            // Key (so glass buttons render active) without activating the app.
            panel.makeKey()

            self.controls.startTicking()
            self.content.setHighlighted(true)
            self.installDismissMonitor()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.207
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = self.panelAlpha
            }
        }
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        controls.stopTicking()
        removeDismissMonitor()
        content.setHighlighted(false)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.184
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            // Don't hide if a new show re-raised the panel during the fade.
            guard let panel, panel.alphaValue < 0.05 else { return }
            panel.orderOut(nil)
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
        glass.style = .regular       // legibility first
        glass.tintColor = nil
        glass.cornerRadius = 22      // artwork radius 8 + inner padding 14

        let card = controls.view
        card.frame = bounds
        card.autoresizingMask = [.width, .height]
        glass.contentView = card

        panel.contentView = glass
        return panel
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
        } else {
            hideTitle()
        }
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
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fadeDuration
            ctx.timingFunction = smoothCurve
            content.animator().alphaValue = 1
        }
    }

    /// Track changed while visible: fade the old title out, swap text + width,
    /// then fade the new title in.
    private func crossfade(to text: String) {
        displayedTitle = text
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = swapDuration
            ctx.timingFunction = smoothCurve
            content.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.isShowing, self.displayedTitle == text else {
                // Hidden or superseded mid-fade — let the newer call own state.
                return
            }
            self.content.setTitle(text)
            self.statusItem.length = self.content.fittingWidth()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = self.swapDuration
                ctx.timingFunction = self.smoothCurve
                self.content.animator().alphaValue = 1
            }
        })
    }

    private func hideTitle() {
        guard isShowing else { return }
        isShowing = false
        displayedTitle = nil

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

        let shuffleRepeat = NSMenuItem(title: "Show shuffle & repeat",
                                       action: #selector(toggleShowShuffleRepeat), keyEquivalent: "")
        shuffleRepeat.target = self
        shuffleRepeat.state = prefs.showShuffleRepeat ? .on : .off
        sub.addItem(shuffleRepeat)

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

    @objc private func toggleShowAllSources() { prefs.filterEnabled.toggle(); updateDisplay() }
    @objc private func toggleSource(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        prefs.toggleSource(id); updateDisplay()
    }
    @objc private func toggleShowArtist()    { prefs.showArtist.toggle();    updateDisplay() }
    @objc private func toggleShowAlbum()     { prefs.showAlbum.toggle();     updateDisplay() }
    @objc private func toggleHideWhenPaused(){ prefs.hideWhenPaused.toggle();updateDisplay() }
    @objc private func toggleShowShuffleRepeat() {
        prefs.showShuffleRepeat.toggle()
        controls.showsShuffleRepeat = prefs.showShuffleRepeat
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
