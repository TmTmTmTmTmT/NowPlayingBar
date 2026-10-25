import AppKit
import Testing
@testable import FloatingLyric

struct PanelGeometryTests {
    private let main = ScreenInfo(id: "1", frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                  visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875))
    private let side = ScreenInfo(id: "2", frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080),
                                  visibleFrame: NSRect(x: 1440, y: 0, width: 1920, height: 1055))
    private let size = CGSize(width: 420, height: 200)

    @Test func perPlacementConstants() {
        #expect(PanelGeometry.cornerRadius(.floating) == 26)
        #expect(PanelGeometry.cornerRadius(.belowCard) == 22)
        #expect(PanelGeometry.cornerRadius(.belowMenuBar) == 18)
        #expect(PanelGeometry.horizontalPadding(.floating) == 24)
        #expect(PanelGeometry.horizontalPadding(.belowCard) == 22)
        #expect(PanelGeometry.horizontalPadding(.belowMenuBar) == 16)
    }

    @Test func plausibleStatusItemFrames() {
        let screens = [main, side]
        // Normal menu bar widget on the main and on the secondary screen.
        #expect(PanelGeometry.isPlausibleStatusItemFrame(NSRect(x: 600, y: 876, width: 200, height: 24), screens: screens))
        #expect(PanelGeometry.isPlausibleStatusItemFrame(NSRect(x: 2000, y: 1056, width: 180, height: 24), screens: screens))
        // Not laid out yet: near the origin, below the screen, empty, or hanging in the middle of a screen.
        #expect(!PanelGeometry.isPlausibleStatusItemFrame(NSRect(x: 0, y: 0, width: 200, height: 24), screens: screens))
        #expect(!PanelGeometry.isPlausibleStatusItemFrame(NSRect(x: 8, y: -11, width: 200, height: 24), screens: screens))
        #expect(!PanelGeometry.isPlausibleStatusItemFrame(NSRect(x: 600, y: 876, width: 0, height: 24), screens: screens))
        #expect(!PanelGeometry.isPlausibleStatusItemFrame(NSRect(x: 600, y: 400, width: 200, height: 24), screens: screens))
        // The secondary screen's strip height does not apply to the main screen.
        #expect(!PanelGeometry.isPlausibleStatusItemFrame(NSRect(x: 600, y: 1056, width: 200, height: 24), screens: screens))
    }

    @Test func heightRules() {
        #expect(PanelGeometry.height(placement: .floating, lyricsHeight: 180, tab: .lyrics) == 180)
        #expect(PanelGeometry.height(placement: .floating, lyricsHeight: 180, tab: .playlist) == 260)
        #expect(PanelGeometry.height(placement: .belowCard, lyricsHeight: 300, tab: .playlist) == 300)
        #expect(PanelGeometry.height(placement: .belowMenuBar, lyricsHeight: 80, tab: .playlist) == 80)
    }

    @Test func widthRules() {
        #expect(PanelGeometry.width(placement: .floating, floatingWidth: 560, cardWidth: 320) == 560)
        #expect(PanelGeometry.width(placement: .belowCard, floatingWidth: 560, cardWidth: 360) == 360)
        #expect(PanelGeometry.width(placement: .belowMenuBar, floatingWidth: 560, cardWidth: 360) == 320)
    }

    @Test func floatingDefaultIsCenteredUnderMenuBar() {
        let f = PanelGeometry.floatingFrame(size: size, screens: [main, side], saved: { _ in nil })
        #expect(f.midX == main.visibleFrame.midX)
        #expect(f.maxY == main.visibleFrame.maxY - 60)
        #expect(f.size == size)
    }

    @Test func floatingUsesSavedTopLeft() {
        let f = PanelGeometry.floatingFrame(size: size, screens: [main, side],
                                            saved: { $0 == "2" ? CGPoint(x: 1600, y: 700) : nil })
        #expect(f == NSRect(x: 1600, y: 500, width: 420, height: 200))
    }

    @Test func floatingFallsBackWhenSavedIsOffScreen() {
        // The side display was unplugged: its saved point is nowhere on the remaining screens.
        let f = PanelGeometry.floatingFrame(size: size, screens: [main],
                                            saved: { _ in CGPoint(x: 1600, y: 700) })
        #expect(f == PanelGeometry.defaultFloatingFrame(size: size, on: main))
    }

    @Test func floatingFallbackSkipsOffScreenAndTriesNextScreen() {
        let f = PanelGeometry.floatingFrame(size: size, screens: [main, side],
                                            saved: { $0 == "1" ? CGPoint(x: 5000, y: 5000) : CGPoint(x: 2000, y: 600) })
        #expect(f.origin == CGPoint(x: 2000, y: 400))
    }

    @Test func barelyVisibleCountsAsOffScreen() {
        let sliver = NSRect(x: -400, y: 300, width: 420, height: 200)       // 20pt visible
        #expect(!PanelGeometry.isOnScreen(sliver, screens: [main]))
        let enough = NSRect(x: -300, y: 300, width: 420, height: 200)       // 120pt visible
        #expect(PanelGeometry.isOnScreen(enough, screens: [main]))
    }

    @Test func belowCardFrame() {
        let card = NSRect(x: 500, y: 700, width: 360, height: 160)
        let f = PanelGeometry.belowCardFrame(card: card, height: 150)
        #expect(f == NSRect(x: 500, y: 700 - 8 - 150, width: 360, height: 150))
    }

    @Test func belowMenuBarCentersUnderItem() {
        let item = NSRect(x: 700, y: 876, width: 200, height: 24)
        let f = PanelGeometry.belowMenuBarFrame(statusItem: item, screen: main.frame, size: CGSize(width: 320, height: 80))
        #expect(f.midX == item.midX)
        #expect(f.maxY == item.minY - 15)
    }

    @Test func belowMenuBarClampsToScreenSides() {
        let screen = main.frame
        let left = PanelGeometry.belowMenuBarFrame(statusItem: NSRect(x: 10, y: 876, width: 40, height: 24),
                                                   screen: screen, size: CGSize(width: 320, height: 80))
        #expect(left.minX == 8)
        let right = PanelGeometry.belowMenuBarFrame(statusItem: NSRect(x: 1420, y: 876, width: 40, height: 24),
                                                    screen: screen, size: CGSize(width: 320, height: 80))
        #expect(right.maxX == screen.maxX - 8)
    }

    @Test func heightChangeKeepsTopEdge() {
        let f = NSRect(x: 100, y: 500, width: 420, height: 200)
        let grown = PanelGeometry.resized(f, height: 260)
        #expect(grown.maxY == f.maxY)
        #expect(grown.minY == 440)
        #expect(grown.minX == f.minX && grown.width == f.width)
        let shrunk = PanelGeometry.resized(f, height: 100)
        #expect(shrunk.maxY == f.maxY)
    }

    @Test func topLeftOfFrame() {
        #expect(PanelGeometry.topLeft(of: NSRect(x: 10, y: 20, width: 30, height: 40)) == CGPoint(x: 10, y: 60))
    }

    @Test func clampPushesFrameIntoVisibleArea() {
        let v = main.visibleFrame
        let anchor = CGPoint(x: 100, y: v.minY + 50)         // 50pt above the screen bottom
        let lyrics = PanelGeometry.frame(anchor: anchor, size: CGSize(width: 420, height: 40))
        #expect(PanelGeometry.clamped(lyrics, screens: [main]) == lyrics)   // fits: unchanged
        let playlist = PanelGeometry.frame(anchor: anchor, size: CGSize(width: 420, height: 260))
        let pushed = PanelGeometry.clamped(playlist, screens: [main])
        #expect(pushed.minY == v.minY)
        #expect(pushed.height == 260 && pushed.minX == 100)
        // Back to the short height: derived from the anchor again, original frame.
        #expect(PanelGeometry.clamped(PanelGeometry.frame(anchor: anchor, size: lyrics.size), screens: [main]) == lyrics)
    }

    @Test func clampPushesDownAndHorizontally() {
        let v = main.visibleFrame
        let top = PanelGeometry.clamped(NSRect(x: -30, y: v.maxY - 10, width: 420, height: 100), into: v)
        #expect(top.maxY == v.maxY && top.minX == v.minX)
        let right = PanelGeometry.clamped(NSRect(x: v.maxX - 100, y: 300, width: 420, height: 100), into: v)
        #expect(right.maxX == v.maxX)
        // Taller than the screen: the top edge stays visible.
        let tall = PanelGeometry.clamped(NSRect(x: 0, y: -500, width: 420, height: 2000), into: v)
        #expect(tall.maxY == v.maxY)
    }

    @Test func clampUsesScreenWithMostOverlap() {
        let f = NSRect(x: 1500, y: 1040, width: 420, height: 100)   // sticks out above the side screen
        let r = PanelGeometry.clamped(f, screens: [main, side])
        #expect(r.maxY == side.visibleFrame.maxY && r.minX == 1500)
    }
}

struct PanelSlideGeometryTests {
    @Test func stripDropsUnderTheCardAndReturns() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let item = NSRect(x: 600, y: 876, width: 200, height: 24)
        let size = CGSize(width: 320, height: 80)
        let card = NSRect(x: 560, y: 700, width: 360, height: 160)
        let docked = PanelGeometry.menuBarStripFrame(dockedCard: card, statusItem: item, screen: screen, size: size)
        #expect(docked == NSRect(x: 560, y: 700 - 8 - 80, width: 360, height: 80))   // card width, gap 8
        let home = PanelGeometry.menuBarStripFrame(dockedCard: nil, statusItem: item, screen: screen, size: size)
        #expect(home == PanelGeometry.belowMenuBarFrame(statusItem: item, screen: screen, size: size))
        #expect(home.width == 320)
    }

    @Test func easingIsMonotonicWithFixedEnds() {
        #expect(PanelGeometry.eased(0) == 0)
        #expect(PanelGeometry.eased(1) == 1)
        var last = 0.0
        for i in 1...20 {
            let v = PanelGeometry.eased(Double(i) / 20)
            #expect(v >= last)
            last = v
        }
        #expect(PanelGeometry.eased(0.5) > 0.5)              // ease-out leaning curve
        #expect(PanelGeometry.eased(0.5, controlPoints: (0.25, 0.25, 0.75, 0.75)) - 0.5 < 1e-6)   // linear sanity
    }

    @Test func interpolationMixesOriginAndSize() {
        let a = NSRect(x: 0, y: 100, width: 320, height: 80)
        let b = NSRect(x: 40, y: 0, width: 360, height: 60)
        #expect(PanelGeometry.interpolate(from: a, to: b, progress: 0) == a)
        #expect(PanelGeometry.interpolate(from: a, to: b, progress: 1) == b)
        #expect(PanelGeometry.interpolate(from: a, to: b, progress: 0.5) == NSRect(x: 20, y: 50, width: 340, height: 70))
    }
}
