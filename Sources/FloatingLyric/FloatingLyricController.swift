import AppKit
import os

private let log = Logger(subsystem: "FloatingLyric", category: "controller")

/// Entry point of the lyrics add-on. The host owns one instance and feeds it
/// track, timeline and glass updates; panels are built behind this facade.
///
/// Main thread only: every method, the provider callbacks and the timers run there.
/// Nothing is created while the feature is off, and panels are built on first use.
public final class FloatingLyricController {
    public let preferences: LyricPreferences
    private let host: LyricHost
    private let lyricsProvider: MusicCacheLyricsProvider
    private let playlistProvider = MusicPlaylistProvider()

    /// Window machinery, built the first time the panel is wanted.
    private struct Stage {
        let panel: FloatingLyricPanel
        let chrome: PanelChrome
        let lyrics: LyricsView
        let playlist: PlaylistView
    }
    private var stage: Stage?

    // Inputs from the host.
    private var track: TrackRef?
    private var timeline: PlaybackTimeline?
    /// Copy of `timeline` readable from the lyrics provider's queue.
    private let timelineLock = NSLock()
    private var timelineSnapshot: PlaybackTimeline?
    private var glass = GlassAppearance.regular
    private var isPlaying = true                 // unknown until the first sample: assume playing
    private var pausedSince: Date?
    private var pauseExpired = false
    private var pauseTimer: Timer?

    // Lyrics lookup.
    private var lookupIdentity: String?          // "bundle|trackKey" of the lookup in flight / done
    private var lyricsRequest = 0
    private var document: LyricsDocument?

    // Playlist.
    private var playlistRequest = 0
    private var playlistLoaded = false
    private var playlistCurrentIndex: Int?

    // Presentation.
    /// Effective placement: the saved one, or `.belowCard` while forced.
    private var placement: LyricPreferences.Placement
    private var forcedCard = false
    /// What the panel's last frame was computed for (true = dropped under the open card).
    private var panelDocked = false
    /// The panel has been asked to be on screen (it may still be fading).
    private var shown = false
    private var floatingPlaced = false
    /// The latest floating top-left this session; newer than the saved value, preferred on re-entry.
    private var lastFloatingOrigin: (screenID: String, point: CGPoint)?
    /// The user's top-left for the floating panel; resizes grow down from it and are clamped
    /// into the screen without being saved (FIX_GUIDE F21).
    private var floatingAnchor: CGPoint?
    private weak var cardWindow: NSWindow?
    private var cardFrame: NSRect?
    /// Between `cardWillShow` and `cardDidHide`.
    private var cardPresented = false
    /// Between `cardWillHide` and `cardDidHide`.
    private var cardFading = false

    /// Screens as placement sees them; tests inject fixed ones.
    var screensProvider: () -> [ScreenInfo] = ScreenInfo.current
    /// One log per stretch of unusable target frames, not one per update.
    private var loggedOffscreen = false

    /// Test hooks.
    var panelFrameForTesting: NSRect? { stage?.panel.frame }
    var isPanelShownForTesting: Bool { shown }
    var panelForTesting: FloatingLyricPanel? { stage?.panel }

    /// Tests build panels without ordering them on screen.
    var suppressWindowOrdering = false

    public convenience init(host: LyricHost, preferences: LyricPreferences = .shared) {
        self.init(host: host, preferences: preferences, lyricsProvider: MusicCacheLyricsProvider())
    }

    init(host: LyricHost, preferences: LyricPreferences, lyricsProvider: MusicCacheLyricsProvider) {
        self.host = host
        self.preferences = preferences
        self.lyricsProvider = lyricsProvider
        self.placement = preferences.placement
    }

    private var isEnabled: Bool {
        LyricTrackState.effectiveEnabled(saved: preferences.enabled, forcedCard: forcedCard)
    }

    private var effectivePlacement: LyricPreferences.Placement {
        LyricTrackState.effectivePlacement(saved: preferences.placement, forcedCard: forcedCard)
    }

    /// The menu bar strip sits under the open card instead of under the widget (PLAN 12.1).
    private var isDockedUnderCard: Bool {
        placement == .belowMenuBar && cardPresented && !cardFading && cardWindow != nil && cardFrame != nil
    }

    deinit {
        pauseTimer?.invalidate()
        lyricsProvider.cancel()
    }

    // MARK: Host input

    /// The playing track changed (nil = nothing playing / filtered out).
    public func update(track newTrack: TrackRef?) {
        let old = track
        track = newTrack
        guard let newTrack else {
            resetTrackState()
            syncVisibility()
            return
        }
        let durationKnown = LyricTrackState.durationBecameKnown(old: old, new: newTrack)
        let changed = identity(of: newTrack) != identity(of: old)
        if changed { playlistLoaded = false; playlistCurrentIndex = nil }
        if isEnabled {
            if changed {
                lookupLyrics(relookup: false)
            } else if durationKnown {
                lookupLyrics(relookup: true)
            }
        }
        if changed { refreshTabs() }
        let wasShown = shown
        syncVisibility()
        // A fresh presentation already fetched; otherwise refetch on a track change.
        if changed && wasShown { fetchPlaylistIfVisible() }
    }

    /// A fresh playback position sample (also sent after a seek).
    public func update(timeline new: PlaybackTimeline) {
        timeline = new
        timelineLock.lock(); timelineSnapshot = new; timelineLock.unlock()
        let wasPlaying = isPlaying
        isPlaying = new.isPlaying
        publishAtmos()
        if new.isPlaying {
            pausedSince = nil
            pauseExpired = false
            pauseTimer?.invalidate()
            pauseTimer = nil
        } else if pausedSince == nil {
            startPauseTimer()
        }
        if isEnabled { stage?.lyrics.update(timeline: new) }
        if wasPlaying != isPlaying {
            stage?.playlist.updateCurrent(index: playlistCurrentIndex, isPlaying: isPlaying)
        }
        syncVisibility()
    }

    /// The host's glass look changed.
    public func apply(glass new: GlassAppearance) {
        glass = new
        applyGlassToStage()
    }

    /// A `lyric.*` option changed in the host's menu.
    public func preferencesDidChange() {
        let newPlacement = effectivePlacement
        if newPlacement != placement {
            // Leaving floating: keep where the panel sits now (FIX_GUIDE F9).
            if placement == .floating, shown, let panel = stage?.panel, panel.placement == .floating {
                saveFloatingOrigin(panel.frame)
            }
            placement = newPlacement
            floatingPlaced = false
            detachFromCard()
        }
        if !isPlaying, pausedSince != nil { schedulePauseTimer() }
        guard isEnabled else {
            tearDownContent()
            dismissPanel()
            return
        }
        if let stage {
            configure(stage, animatedTab: false)
            stage.lyrics.reload()
            if let timeline { stage.lyrics.update(timeline: timeline) }
        }
        if let track, lookupIdentity != identity(of: track) { lookupLyrics(relookup: false) }
        let wasShown = shown
        syncVisibility()
        if wasShown { fetchPlaylistIfVisible() }
    }

    // MARK: Card hooks (PLAN 11.3)

    /// The control card is about to fade in; `frame` is its final screen frame.
    public func cardWillShow(frame: NSRect, cardWindow: NSWindow) {
        if self.cardWindow !== cardWindow { detachFromCard() }
        self.cardWindow = cardWindow
        cardFrame = frame
        cardPresented = true
        cardFading = false
        // Below card: fades in with the card. Below menu bar: the strip slides under the card
        // (same moment as the card's fade-in). Floating: untouched.
        syncVisibility()
    }

    /// The control card starts fading out.
    public func cardWillHide() {
        guard cardPresented else { return }
        cardFading = true
        syncVisibility()   // below card: fades out with the card; menu bar strip: slides back up
    }

    /// The control card is fully hidden.
    public func cardDidHide() {
        cardPresented = false
        cardFading = false
        if placement == .belowCard, !shown { detachFromCard() }
        syncVisibility()
    }

    /// The host shows its card permanently with lyrics attached below it
    /// ("Always shown with Lyrics Card"): lyrics count as enabled, placement is
    /// below the card, and the paused auto-hide is off. Preferences stay as saved.
    public func setForcedCardAttachment(_ on: Bool) {
        guard on != forcedCard else { return }
        forcedCard = on
        preferencesDidChange()               // re-derives enabled, placement and visibility
    }

    /// The menu bar widget moved or changed width. The host also calls this after it moved
    /// the open card without `cardWillShow`, so the card's current frame is re-read here.
    public func statusItemDidMove() {
        if cardPresented, let cardWindow { cardFrame = cardWindow.frame }
        guard placement == .belowMenuBar || placement == .belowCard else { return }
        syncVisibility()
        updateFrame(animated: false)
    }

    // MARK: Lyrics

    private func identity(of track: TrackRef?) -> String? {
        track.map { "\($0.sourceBundleID)|\(LyricTrackState.key(for: $0))" }
    }

    /// `relookup`: the duration just became known; keep what is on screen when it is the same song.
    private func lookupLyrics(relookup: Bool) {
        guard let track else { return }
        lookupIdentity = identity(of: track)
        lyricsRequest += 1
        let request = lyricsRequest
        if !relookup { lyricsMissing = false; atmosTrack = false }
        guard LyricTrackState.supportsLyrics(sourceBundleID: track.sourceBundleID) else {
            lyricsProvider.cancel()
            document = nil
            stage?.lyrics.show(document: nil, emptyState: .none)   // the panel is hidden for other sources
            return
        }
        if !relookup {
            document = nil
            stage?.lyrics.show(document: nil, emptyState: .loading)
        }
        let duration = track.duration
        // Re-read on every attempt: the first samples of a new track may still be the old one's.
        lyricsProvider.lyrics(for: track, trackStart: { [weak self] in
            guard let self else { return nil }
            self.timelineLock.lock(); defer { self.timelineLock.unlock() }
            return LyricTrackState.trackStart(timeline: self.timelineSnapshot, trackDuration: duration)
        }) { [weak self] result in
            guard let self, request == self.lyricsRequest else { return }
            let doc = result.document
            guard LyricTrackState.shouldReplace(current: self.document, with: doc, isRelookup: relookup) else { return }
            self.document = doc
            log.debug("lyrics result id=\(doc?.songID ?? "none", privacy: .public) lines=\(doc?.lines.count ?? 0, privacy: .public) noSession=\(result.noSessionEntries, privacy: .public)")
            let empty = LyricTrackState.emptyState(for: result)
            self.stage?.lyrics.show(document: doc, emptyState: empty)
            self.lyricsMissing = LyricTrackState.hidesPanel(document: doc, emptyState: empty)
            self.atmosTrack = doc?.isAtmos == true && AtmosSetting.isEnabled(rawValue: AtmosSetting.rawValue())
            self.syncVisibility()
        }
    }

    /// Track gone: forget lookups, lyrics and playlist state.
    private func resetTrackState() {
        lyricsProvider.cancel()
        lyricsRequest += 1
        playlistRequest += 1
        lookupIdentity = nil
        document = nil
        lyricsMissing = false
        atmosTrack = false
        playlistLoaded = false
        playlistCurrentIndex = nil
        stage?.lyrics.show(document: nil, emptyState: .none)
    }

    /// Feature switched off: stop work, keep the (hidden) windows for a cheap re-enable.
    private func tearDownContent() {
        lyricsProvider.cancel()
        lyricsRequest += 1
        playlistRequest += 1
        lookupIdentity = nil
        document = nil
        lyricsMissing = false
        atmosTrack = false
        stage?.lyrics.show(document: nil, emptyState: .none)
    }

    // MARK: Playlist

    private var playlistAvailable: Bool {
        LyricTrackState.playlistTabAvailable(sourceBundleID: track?.sourceBundleID) && placement != .belowMenuBar
    }

    private var effectiveTab: LyricPreferences.Tab {
        LyricTrackState.effectiveTab(preferred: preferences.lastTab, playlistAvailable: playlistAvailable)
    }

    /// Asks Music for the playlist only while its tab is on screen: when it opens and when the
    /// track changes (which also retries after a failure).
    private func fetchPlaylistIfVisible() {
        guard shown, isEnabled, effectiveTab == .playlist, let stage else { return }
        playlistRequest += 1
        let request = playlistRequest
        if !playlistLoaded { stage.playlist.showLoading() }
        playlistProvider.fetch { [weak self] result in
            guard let self, request == self.playlistRequest else { return }
            self.playlistLoaded = true
            if case .snapshot(let snap) = result { self.playlistCurrentIndex = snap.currentIndex }
            self.stage?.playlist.show(result: result)
            self.stage?.playlist.updateCurrent(index: self.playlistCurrentIndex, isPlaying: self.isPlaying)
        }
    }

    // MARK: Stage

    private func ensureStage() -> Stage {
        if let stage { return stage }
        let lyrics = LyricsView(preferences: preferences)
        let playlist = PlaylistView(frame: .zero)
        let chrome = PanelChrome(lyricsView: lyrics, playlistView: playlist)
        let panel = FloatingLyricPanel(chrome: chrome)
        let s = Stage(panel: panel, chrome: chrome, lyrics: lyrics, playlist: playlist)
        stage = s

        lyrics.onUserScrollChange = { [weak self] scrolling in
            guard let self else { return }
            self.userScrolling = scrolling
            if !scrolling { self.syncVisibility() }
        }
        lyrics.onSeek = { [weak self] seconds in self?.host.seek(seconds) }
        playlist.onSelect = { [weak self] index in self?.playlistProvider.play(index: index) }
        playlist.artworkLoader = { [weak self] index, done in
            guard let self else { done(nil); return }
            self.playlistProvider.artwork(index: index, completion: done)
        }
        chrome.onTabSelected = { [weak self] tab in self?.tabClicked(tab) }
        panel.onUserMoved = { [weak self] frame in
            guard let self, self.placement == .floating else { return }
            self.saveFloatingOrigin(frame)
        }

        applyGlassToStage()
        configure(s, animatedTab: false)
        if let doc = document {
            lyrics.show(document: doc, emptyState: .none)
        } else if let track {
            let supported = LyricTrackState.supportsLyrics(sourceBundleID: track.sourceBundleID)
            lyrics.show(document: nil, emptyState: supported ? .loading : .none)
        }
        if let timeline { lyrics.update(timeline: timeline) }
        return s
    }

    private func applyGlassToStage() {
        guard let stage else { return }
        stage.chrome.apply(glass: glass)
        // The pinned look lives on the chrome root; the content views inherit it (PLAN #8).
        var inner = glass
        inner.pinnedDark = nil
        stage.lyrics.apply(glass: inner)
        stage.playlist.apply(glass: inner)
    }

    /// Placement-dependent look and tab state.
    private func configure(_ s: Stage, animatedTab: Bool) {
        s.panel.suppressOrdering = suppressWindowOrdering
        s.panel.apply(placement: placement, locked: preferences.floatingLocked,
                      clickThrough: preferences.clickThrough)
        s.lyrics.placement = placement
        s.lyrics.horizontalPadding = PanelGeometry.horizontalPadding(placement)
        s.chrome.configure(placement: placement, tabsAvailable: playlistAvailable)
        s.chrome.setTab(effectiveTab, animated: animatedTab)
    }

    private func refreshTabs() {
        guard let stage else { return }
        configure(stage, animatedTab: shown)
        if shown { updateFrame(animated: true) }
    }

    private func tabClicked(_ tab: LyricPreferences.Tab) {
        preferences.lastTab = tab
        guard let stage else { return }
        stage.chrome.setTab(effectiveTab, animated: true)
        updateFrame(animated: true)
        if effectiveTab == .playlist { fetchPlaylistIfVisible() }
    }

    // MARK: Visibility

    /// The user is scrolling the lyrics: the paused auto-hide waits.
    private var userScrolling = false
    /// The lookup finished without lyrics: the lyrics tab has nothing to show, so the panel hides.
    private var lyricsMissing = false

    /// The current song has an Atmos version and Music's Atmos setting is on (known from the lyrics lookup).
    private var atmosTrack = false { didSet { publishAtmos() } }
    private var lastAtmosPublished = false
    /// true while an Atmos song is playing; called on the main thread when it changes.
    public var onAtmosChange: ((Bool) -> Void)?

    private func publishAtmos() {
        let now = isEnabled && atmosTrack && isPlaying
        guard now != lastAtmosPublished else { return }
        lastAtmosPublished = now
        onAtmosChange?(now)
    }

    private var pausedFor: TimeInterval {
        if pauseExpired { return preferences.pausedHideDelay }
        return pausedSince.map { Date().timeIntervalSince($0) } ?? 0
    }

    private func startPauseTimer() {
        pausedSince = Date()
        schedulePauseTimer()
    }

    /// (Re)arms the hide timer for the time left of `pausedHideDelay`; already past = hide now.
    /// Also called when the setting changes during a pause (PLAN 12.11).
    private func schedulePauseTimer() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        guard let pausedSince else { return }
        let remaining = preferences.pausedHideDelay - Date().timeIntervalSince(pausedSince)
        pauseExpired = remaining <= 0
        guard remaining > 0 else { return }
        pauseTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.pauseExpired = true
            self.pauseTimer = nil
            self.syncVisibility()
        }
    }

    /// Whether the panel should be on screen right now: the visibility rule plus placement needs.
    private func wantsPanel() -> Bool {
        guard LyricTrackState.isVisible(enabled: isEnabled, hasTrack: track != nil,
                                        isMusicSource: track.map { LyricTrackState.supportsLyrics(sourceBundleID: $0.sourceBundleID) } ?? false,
                                        isPlaying: isPlaying,
                                        pausedFor: LyricTrackState.effectivePausedFor(pausedFor, forcedCard: forcedCard,
                                                                                  scrolling: userScrolling),
                                        hideDelay: preferences.pausedHideDelay)
        else { return false }
        if lyricsMissing && effectiveTab == .lyrics { return false }
        switch placement {
        case .floating:
            return true
        case .belowCard:
            return cardPresented && !cardFading && cardWindow != nil
        case .belowMenuBar:
            // Open card: docked under it even without a usable widget frame (PLAN 12.9).
            return isDockedUnderCard || validStatusItemFrame() != nil
        }
    }

    /// The host's widget frame, or nil while it is not laid out yet (FIX_GUIDE F5).
    private func validStatusItemFrame() -> NSRect? {
        guard let item = host.statusItemFrame(),
              PanelGeometry.isPlausibleStatusItemFrame(item, screens: screensProvider()) else { return nil }
        return item
    }

    private func syncVisibility() {
        if wantsPanel() { presentPanel() } else { dismissPanel() }
    }

    private func presentPanel() {
        let s = ensureStage()
        if !shown { configure(s, animatedTab: false) }
        guard let frame = visibleTargetFrame(for: s) else { dismissPanel(); return }
        attachToCardIfNeeded(s.panel)
        let docked = isDockedUnderCard
        if shown {
            if docked != panelDocked {
                panelDocked = docked
                s.panel.slide(to: frame)             // always from the current frame to the current target
            } else {
                s.panel.setPanelFrame(frame, animated: true)
            }
            return
        }
        panelDocked = docked
        shown = true
        s.panel.setPanelFrame(frame, animated: false)
        s.panel.fadeIn()
        if let timeline { s.lyrics.update(timeline: timeline) }
        fetchPlaylistIfVisible()
    }

    private func dismissPanel() {
        guard shown, let panel = stage?.panel else { return }
        shown = false
        userScrolling = false
        floatingPlaced = false
        playlistRequest += 1
        panel.fadeOut { [weak self] in
            guard let self, !self.shown else { return }
            self.detachFromCard()
        }
    }

    private func updateFrame(animated: Bool) {
        guard shown, let s = stage else { return }
        guard let frame = visibleTargetFrame(for: s) else { dismissPanel(); return }
        s.panel.setPanelFrame(frame, animated: animated)
    }

    // MARK: Frames

    private func desiredSize() -> CGSize {
        let lyricsHeight = LyricsView.preferredHeight(lines: preferences.lines,
                                                      textSize: preferences.textSize, placement: placement)
        let height = PanelGeometry.height(placement: placement, lyricsHeight: lyricsHeight, tab: effectiveTab)
        let width = PanelGeometry.width(placement: placement, floatingWidth: preferences.floatingWidth,
                                        cardWidth: cardFrame?.width)
        return CGSize(width: width, height: height)
    }

    /// Last safety net for every placement: never order a panel that would not be seen.
    private func visibleTargetFrame(for s: Stage) -> NSRect? {
        guard let frame = targetFrame(for: s) else { return nil }
        if PanelGeometry.isOnScreen(frame, screens: screensProvider()) {
            loggedOffscreen = false
            return frame
        }
        if !loggedOffscreen {
            loggedOffscreen = true
            log.debug("panel target off screen placement=\(self.placement.rawValue, privacy: .public) x=\(Int(frame.minX), privacy: .public) y=\(Int(frame.minY), privacy: .public) w=\(Int(frame.width), privacy: .public) h=\(Int(frame.height), privacy: .public)")
        }
        return nil
    }

    private func targetFrame(for s: Stage) -> NSRect? {
        let size = desiredSize()
        switch placement {
        case .floating:
            if shown, floatingPlaced {
                // Grow downward from the user's anchor, then push into the screen (not saved).
                let anchor = floatingAnchor ?? PanelGeometry.topLeft(of: s.panel.frame)
                return PanelGeometry.clamped(PanelGeometry.frame(anchor: anchor, size: size),
                                             screens: screensProvider())
            }
            let screens = screensProvider()
            guard !screens.isEmpty else { return nil }
            floatingPlaced = true
            let placed = PanelGeometry.floatingFrame(size: size, screens: screens, saved: { [preferences, lastFloatingOrigin] id in
                // This session's last spot wins over the saved one.
                if let last = lastFloatingOrigin { return last.screenID == id ? last.point : nil }
                return preferences.floatingOrigin(screenID: id)
            })
            floatingAnchor = PanelGeometry.topLeft(of: placed)
            return PanelGeometry.clamped(placed, screens: screens)
        case .belowCard:
            guard let cardFrame else { return nil }
            return PanelGeometry.belowCardFrame(card: cardFrame, height: size.height)
        case .belowMenuBar:
            if isDockedUnderCard, let cardFrame {
                return PanelGeometry.belowCardFrame(card: cardFrame, height: size.height)
            }
            guard let item = validStatusItemFrame() else { return nil }
            let screens = screensProvider()
            let mid = CGPoint(x: item.midX, y: item.midY)
            guard let screen = screens.first(where: { $0.frame.contains(mid) }) ?? screens.first else { return nil }
            return PanelGeometry.menuBarStripFrame(dockedCard: isDockedUnderCard ? cardFrame : nil,
                                                   statusItem: item, screen: screen.frame, size: size)
        }
    }

    private func saveFloatingOrigin(_ frame: NSRect) {
        let screens = screensProvider()
        let mid = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = screens.first(where: { $0.frame.contains(mid) }) ?? screens.first else { return }
        let topLeft = PanelGeometry.topLeft(of: frame)
        lastFloatingOrigin = (screen.id, topLeft)
        floatingAnchor = topLeft
        preferences.setFloatingOrigin(topLeft, screenID: screen.id)
    }

    // MARK: Card attachment

    private func attachToCardIfNeeded(_ panel: FloatingLyricPanel) {
        guard placement == .belowCard, let cardWindow else { return }
        if panel.parent !== cardWindow {
            panel.parent?.removeChildWindow(panel)
            cardWindow.addChildWindow(panel, ordered: .above)
        }
    }

    private func detachFromCard() {
        guard let panel = stage?.panel, let parent = panel.parent else { return }
        parent.removeChildWindow(panel)
    }
}
