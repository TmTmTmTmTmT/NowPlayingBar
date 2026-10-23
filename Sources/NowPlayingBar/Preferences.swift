import AppKit

/// Persists user choices: which sources to show, display options, and the
/// marquee geometry. Backed by `UserDefaults`.
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let firstRunDone      = "firstRunDone"
        static let filterEnabled     = "filterEnabled"
        static let enabledSources    = "enabledSources"
        static let discoveredSources = "discoveredSources"
        static let showArtist        = "showArtist"
        static let hideWhenPaused    = "hideWhenPaused"
        static let scrollSpeed       = "scrollSpeed"
        static let maxWidth          = "maxWidth"
        static let showAlbum         = "showAlbum"
        static let showShuffleRepeat = "showShuffleRepeat"
        static let glassClear        = "glassClear"
    }

    /// Width menu presets (points).
    static let widthPresets: [(name: String, value: CGFloat)] = [
        ("Narrow", 120), ("Medium", 176), ("Wide", 240), ("Extra wide", 320),
    ]

    /// Allowed widget max width (points).
    static let widthRange: ClosedRange<CGFloat> = 80...600

    static let commonSources: [(id: String, name: String)] = [
        ("com.apple.Music",          "Apple Music"),
        ("com.apple.Safari",         "Safari"),
        ("com.spotify.client",       "Spotify"),
        ("com.google.Chrome",        "Chrome"),
        ("com.apple.podcasts",       "Podcasts"),
        ("com.apple.TV",             "TV"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.brave.Browser",        "Brave"),
        ("org.mozilla.firefox",      "Firefox"),
    ]

    /// O(1) lookup set built once from `commonSources`.
    private static let commonSourceIDs: Set<String> =
        Set(commonSources.map { $0.id })

    /// O(1) name lookup built once from `commonSources`.
    private static let commonSourceNames: [String: String] =
        Dictionary(uniqueKeysWithValues: commonSources.map { ($0.id, $0.name) })

    // MARK: - In-memory cache
    // Avoids allocating a new Set<String> on every shouldDisplay() call
    // (which is invoked on every monitor update, ~7x/second while playing).

    private var _enabledSources: Set<String>?
    private func cachedEnabledSources() -> Set<String> {
        if let c = _enabledSources { return c }
        let loaded = Set(defaults.stringArray(forKey: Key.enabledSources) ?? [])
        _enabledSources = loaded
        return loaded
    }

    // MARK: - Init

    private init() {
        // Defaults for keys added after the first release: the firstRunDone
        // block below never re-runs for existing users.
        defaults.register(defaults: [
            Key.maxWidth:          176.0,
            Key.showAlbum:         false,
            Key.showShuffleRepeat: false,
            Key.glassClear:        false,
        ])
        if !defaults.bool(forKey: Key.firstRunDone) {
            defaults.set(true,  forKey: Key.firstRunDone)
            defaults.set(true,  forKey: Key.filterEnabled)
            defaults.set(["com.apple.Music", "com.apple.Safari", "com.spotify.client"],
                         forKey: Key.enabledSources)
            defaults.set(false, forKey: Key.showArtist)
            defaults.set(false, forKey: Key.hideWhenPaused)
            defaults.set(40.0,  forKey: Key.scrollSpeed)
        }
    }

    // MARK: - Options

    var filterEnabled: Bool {
        get { defaults.bool(forKey: Key.filterEnabled) }
        set { defaults.set(newValue, forKey: Key.filterEnabled) }
    }

    var showArtist: Bool {
        get { defaults.bool(forKey: Key.showArtist) }
        set { defaults.set(newValue, forKey: Key.showArtist) }
    }

    var hideWhenPaused: Bool {
        get { defaults.bool(forKey: Key.hideWhenPaused) }
        set { defaults.set(newValue, forKey: Key.hideWhenPaused) }
    }

    var showAlbum: Bool {
        get { defaults.bool(forKey: Key.showAlbum) }
        set { defaults.set(newValue, forKey: Key.showAlbum) }
    }

    /// Card glass: false = regular, true = clear (with a very light tint).
    var glassClear: Bool {
        get { defaults.bool(forKey: Key.glassClear) }
        set { defaults.set(newValue, forKey: Key.glassClear) }
    }

    var showShuffleRepeat: Bool {
        get { defaults.bool(forKey: Key.showShuffleRepeat) }
        set { defaults.set(newValue, forKey: Key.showShuffleRepeat) }
    }

    /// Widget max width, clamped to `widthRange` on read and write.
    var maxWidth: CGFloat {
        get {
            let v = CGFloat(defaults.double(forKey: Key.maxWidth))
            return min(max(v, Self.widthRange.lowerBound), Self.widthRange.upperBound)
        }
        set {
            let v = min(max(newValue, Self.widthRange.lowerBound), Self.widthRange.upperBound)
            defaults.set(Double(v), forKey: Key.maxWidth)
        }
    }

    var scrollSpeed: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.scrollSpeed)) }
        set { defaults.set(Double(newValue), forKey: Key.scrollSpeed) }
    }

    // MARK: - Source whitelist

    func isEnabled(_ id: String) -> Bool {
        cachedEnabledSources().contains(id)
    }

    func shouldDisplay(_ id: String) -> Bool {
        !filterEnabled || isEnabled(id)
    }

    func toggleSource(_ id: String) {
        var set = cachedEnabledSources()
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        _enabledSources = set                                 // update cache
        defaults.set(Array(set), forKey: Key.enabledSources)
    }

    // MARK: - Discovered sources

    private func discoveredSources() -> [String: String] {
        (defaults.dictionary(forKey: Key.discoveredSources) as? [String: String]) ?? [:]
    }

    func recordDiscovered(id: String) {
        guard !Self.commonSourceIDs.contains(id) else { return }  // O(1)
        var dict = discoveredSources()
        guard dict[id] == nil else { return }
        dict[id] = Self.resolveName(for: id) ?? id
        defaults.set(dict, forKey: Key.discoveredSources)
    }

    func menuSources() -> [(id: String, name: String)] {
        var result = Self.commonSources
        let known = Self.commonSourceIDs
        for (id, name) in discoveredSources().sorted(by: { $0.value < $1.value })
            where !known.contains(id) {
            result.append((id, name))
        }
        return result
    }

    func displayName(for id: String) -> String {
        if let name = Self.commonSourceNames[id] { return name }  // O(1)
        if let name = discoveredSources()[id]    { return name }
        return Self.resolveName(for: id) ?? id
    }

    private static func resolveName(for id: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return nil
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
