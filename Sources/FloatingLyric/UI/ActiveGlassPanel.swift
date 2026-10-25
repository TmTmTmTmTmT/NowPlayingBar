import AppKit

/// Panel base class whose glass keeps the active (key-window) look while
/// another app is frontmost. Hosts subclass it for their own glass panels.
///
/// `NSGlassEffectView` draws its edge highlight from AppKit's private window
/// "active appearance" predicates; there is no public switch (FIX_GUIDE F4).
/// The overrides below are plain Objective-C methods registered under those
/// selector names: AppKit calls them only where it implements the selector, and
/// on an OS that lacks one the method is simply never called. They change what
/// the window *looks* like, not its key state: `canBecomeKey` and event routing
/// are untouched, so the panel never steals focus.
open class ActiveGlassPanel: NSPanel {
    /// Private predicates that decide the active glass look, newest naming first.
    /// The overrides cover exactly these; keep both in sync.
    static let candidateSelectors: [String] = [
        "_hasActiveAppearance",
        "_hasActiveAppearanceIgnoringKeyFocus",
        "_hasKeyAppearance",
        "hasKeyAppearance",
        "_sharesParentKeyState",
    ]

    /// The candidates this OS actually implements (diagnostics and tests).
    public static var supportedSelectors: [String] {
        candidateSelectors.filter { NSWindow.instancesRespond(to: NSSelectorFromString($0)) }
    }

    @objc(_hasActiveAppearance)
    func alwaysActiveAppearance() -> Bool { true }

    @objc(_hasActiveAppearanceIgnoringKeyFocus)
    func alwaysActiveAppearanceIgnoringKeyFocus() -> Bool { true }

    @objc(_hasKeyAppearance)
    func alwaysKeyAppearance() -> Bool { true }

    /// The un-prefixed predicate is the one the glass actually reads on key
    /// changes on this OS (FIX_GUIDE F6 probe), along with the ignoring-key-focus one.
    @objc(hasKeyAppearance)
    func alwaysHasKeyAppearance() -> Bool { true }

    @objc(_sharesParentKeyState)
    func alwaysSharesParentKeyState() -> Bool { true }

    // MARK: Forced refresh

    /// Re-evaluation trigger AppKit sends to a window's views on a key change.
    static let forcedRefreshSelector = NSSelectorFromString("_sendForcedWindowChangedKeyState")

    public override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                         backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        ActiveGlassBroadcaster.shared.register(self)
    }
}

/// Key state changes reach only the window that gains or loses key, so a second
/// glass panel keeps its old look. On any key or app-activation change this
/// asks every visible `ActiveGlassPanel` to re-evaluate, one runloop turn later
/// (FIX_GUIDE F6). It never changes key state itself.
@MainActor
final class ActiveGlassBroadcaster: NSObject {
    static let shared = ActiveGlassBroadcaster()

    private let panels = NSHashTable<ActiveGlassPanel>.weakObjects()
    private var isScheduled = false
    private var isBroadcasting = false
    /// Completed broadcasts (tests).
    private(set) var broadcastCount = 0

    private override init() {
        super.init()
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        ]
        for name in names {
            center.addObserver(self, selector: #selector(stateChanged(_:)), name: name, object: nil)
        }
    }

    var registeredCount: Int { panels.allObjects.count }

    func register(_ panel: ActiveGlassPanel) { panels.add(panel) }

    @objc private func stateChanged(_ note: Notification) {
        // The forced refresh may itself post key notifications: ignore those.
        guard !isBroadcasting, !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isScheduled = false
            self?.broadcast()
        }
    }

    /// Sends the forced refresh to every visible panel that implements it.
    func broadcast() {
        guard !isBroadcasting else { return }
        isBroadcasting = true
        defer { isBroadcasting = false }
        guard NSWindow.instancesRespond(to: ActiveGlassPanel.forcedRefreshSelector) else { return }
        for panel in panels.allObjects where panel.isVisible {
            _ = panel.perform(ActiveGlassPanel.forcedRefreshSelector)
        }
        broadcastCount += 1
    }
}
