import AppKit
import Testing
@testable import FloatingLyric

@MainActor
@Suite struct ActiveGlassPanelTests {
    private func makePanels() -> (plain: NSPanel, glass: ActiveGlassPanel) {
        _ = NSApplication.shared
        let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        let rect = NSRect(x: 0, y: 0, width: 100, height: 50)
        return (NSPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: true),
                ActiveGlassPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: true))
    }

    @Test func candidateTableIsNonEmptyAndNamedAfterKeyLook() {
        #expect(!ActiveGlassPanel.candidateSelectors.isEmpty)
        #expect(ActiveGlassPanel.candidateSelectors.allSatisfy { $0.contains("Appearance") || $0.contains("KeyState") })
    }

    @Test func everyCandidateIsOverriddenInTheSubclass() {
        for name in ActiveGlassPanel.candidateSelectors {
            let sel = NSSelectorFromString(name)
            #expect(ActiveGlassPanel.instancesRespond(to: sel), "\(name)")
        }
    }

    @Test func overridesFlipTheRuntimePredicatesOnlyWhereTheOSHasThem() {
        let (plain, glass) = makePanels()
        for name in ActiveGlassPanel.supportedSelectors {
            // The plain, never-key window is inactive; the subclass reports active.
            #expect((plain.value(forKey: name) as? Bool) == false, "\(name)")
            #expect((glass.value(forKey: name) as? Bool) == true, "\(name)")
        }
    }

    @Test func doesNotBecomeKeyOrMain() {
        let (_, glass) = makePanels()
        #expect(glass.isKeyWindow == false)
        #expect(glass.isMainWindow == false)
    }

    @Test func floatingPanelIsAnActiveGlassPanel() {
        let panel = FloatingLyricPanel(chrome: PanelChrome(
            lyricsView: LyricsView(preferences: LyricPreferences(defaults: UserDefaults(suiteName: "AGP-\(UUID().uuidString)")!)),
            playlistView: PlaylistView(frame: .zero)))
        #expect((panel as NSWindow) is ActiveGlassPanel)
    }

    @Test func lyricPanelWindowAppearanceIsAlwaysDarkAqua() {
        let panel = FloatingLyricPanel(chrome: PanelChrome(
            lyricsView: LyricsView(preferences: LyricPreferences(defaults: UserDefaults(suiteName: "AGP-\(UUID().uuidString)")!)),
            playlistView: PlaylistView(frame: .zero)))
        #expect(panel.appearance?.name == .darkAqua)
    }

    @Test func broadcasterTracksPanelsWeaklyAndSkipsHidden() {
        let broadcaster = ActiveGlassBroadcaster.shared
        let before = broadcaster.registeredCount
        weak var weakGlass: ActiveGlassPanel?
        autoreleasepool {
            let glass = makePanels().glass
            weakGlass = glass
            #expect(broadcaster.registeredCount == before + 1)
        }
        let count = broadcaster.broadcastCount
        broadcaster.broadcast()   // hidden panel: must not throw or retain
        #expect(broadcaster.broadcastCount == count + 1 || !NSWindow.instancesRespond(to: ActiveGlassPanel.forcedRefreshSelector))
        #expect(weakGlass == nil)
        #expect(broadcaster.registeredCount == before)
    }

    @Test func broadcastDoesNotRecurseOnKeyNotifications() async {
        let broadcaster = ActiveGlassBroadcaster.shared
        let (_, glass) = makePanels()
        glass.orderFrontRegardless()
        defer { glass.orderOut(nil) }
        let count = broadcaster.broadcastCount
        // A burst of notifications coalesces into one broadcast on the next turn.
        for _ in 0..<5 { NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: glass) }
        #expect(broadcaster.broadcastCount == count)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(broadcaster.broadcastCount <= count + 2)
        #expect(broadcaster.broadcastCount >= count + 1 || !NSWindow.instancesRespond(to: ActiveGlassPanel.forcedRefreshSelector))
    }
}
