import AppKit
import ImageIO

/// One row of the current Music playlist. `index` is the 1-based AppleScript track index.
struct PlaylistTrack: Equatable {
    var index: Int
    var title: String
    var artist: String
    var duration: TimeInterval
}

/// `tracks` is a window of at most `PlaylistParser.maxTracks` rows around the
/// current track; `firstIndex` is the AppleScript index of its first row and
/// `totalCount` the length of the whole playlist (PLAN §3.5 v2).
struct PlaylistSnapshot: Equatable {
    var name: String
    var tracks: [PlaylistTrack]
    var currentIndex: Int?
    var totalCount: Int
    var firstIndex: Int
    /// Music's shuffle switch: the real play order then differs from the list order.
    var shuffleEnabled = false

    /// True when rows were left out, so the UI can say which range it shows.
    var isTruncated: Bool { tracks.count < totalCount }
}

enum PlaylistResult {
    case snapshot(PlaylistSnapshot)
    case noPlaylist
    case denied
    case failed
}

/// Parses the osascript output of `MusicPlaylistProvider.fetchScript`.
/// Layout: name RS currentIndex RS totalCount RS firstIndex RS titles RS artists RS durations RS shuffle
/// (RS = U+001E, items joined by US = U+001F). Indexes are absolute AppleScript indexes.
enum PlaylistParser {
    static let sectionSeparator: Character = "\u{1E}"
    static let itemSeparator: Character = "\u{1F}"
    static let maxTracks = 1000
    /// Rows kept before the current track when the playlist has to be cut.
    static let tracksBeforeCurrent = 300

    /// First and last index (1-based, inclusive) of the window to fetch. The
    /// AppleScript side applies the same arithmetic; this copy is unit-tested.
    static func window(total: Int, current: Int?) -> (first: Int, last: Int) {
        guard total > 0 else { return (1, 0) }
        guard total > maxTracks else { return (1, total) }
        let centre = min(max(current ?? 1, 1), total)
        var first = max(1, centre - tracksBeforeCurrent)
        var last = first + maxTracks - 1
        if last > total { last = total; first = total - maxTracks + 1 }
        return (first, last)
    }

    static func parse(_ output: String) -> PlaylistSnapshot? {
        // omittingEmptySubsequences: false keeps empty sections (empty playlist) in place.
        let sections = output.split(separator: sectionSeparator, omittingEmptySubsequences: false)
            .map(String.init)
        guard sections.count == 8 else { return nil }

        let name = sections[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let current = Int(sections[1].trimmingCharacters(in: .whitespacesAndNewlines))
        guard let total = Int(sections[2].trimmingCharacters(in: .whitespacesAndNewlines)), total >= 0,
              let first = Int(sections[3].trimmingCharacters(in: .whitespacesAndNewlines)), first >= 1
        else { return nil }

        func items(_ s: String) -> [String] {
            // Trailing newline from osascript lands on the last section only.
            let trimmed = s.trimmingCharacters(in: .newlines)
            if trimmed.isEmpty { return [] }
            return trimmed.split(separator: itemSeparator, omittingEmptySubsequences: false).map(String.init)
        }
        let shuffle = sections[7].trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        let titles = items(sections[4])
        let artists = items(sections[5])
        let durations = items(sections[6])
        guard titles.count == artists.count, titles.count == durations.count else { return nil }

        var tracks: [PlaylistTrack] = []
        tracks.reserveCapacity(min(titles.count, maxTracks))
        for i in 0..<min(titles.count, maxTracks) {
            tracks.append(PlaylistTrack(index: first + i, title: titles[i], artist: artists[i],
                                        duration: parseDuration(durations[i])))
        }
        // The current track may lie outside the window (never for a window built around it).
        let validCurrent = current.flatMap { c in tracks.contains { $0.index == c } ? c : nil }
        return PlaylistSnapshot(name: name, tracks: tracks, currentIndex: validCurrent,
                                totalCount: max(total, tracks.count), firstIndex: first,
                                shuffleEnabled: shuffle)
    }

    /// Locale-dependent output: "193.615" or "193,615".
    static func parseDuration(_ s: String) -> TimeInterval {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return Double(t) ?? 0
    }
}

/// Reads the current Music playlist through one osascript call and plays/looks up rows on demand.
/// Not thread-safe: call from the main thread.
final class MusicPlaylistProvider {
    private enum Metrics {
        static let timeout: TimeInterval = 5
        static let artworkConcurrency = 2
        static let thumbnailPixels = 64
        static let artworkCacheLimit = 300
    }

    private static let fetchScript = """
    if application "Music" is not running then return "notrunning"
    set us to character id 31
    set rs to character id 30
    try
      tell application "Music"
        set pl to current playlist
        set plName to name of pl
        set cnt to count of tracks of pl
        set ci to 0
        try
          set ci to index of current track
        end try
        set sh to false
        try
          set sh to shuffle enabled
        end try
        -- Window of at most 1000 rows around the current track (PLAN §3.5 v2).
        set first_ to 1
        set last_ to cnt
        if cnt > 1000 then
          set centre to ci
          if centre < 1 then set centre to 1
          if centre > cnt then set centre to cnt
          set first_ to centre - 300
          if first_ < 1 then set first_ to 1
          set last_ to first_ + 999
          if last_ > cnt then
            set last_ to cnt
            set first_ to cnt - 999
          end if
        end if
        if cnt is 0 then
          set n to {}
          set a to {}
          set d to {}
        else
          set n to name of (tracks first_ thru last_ of pl)
          set a to artist of (tracks first_ thru last_ of pl)
          set d to duration of (tracks first_ thru last_ of pl)
        end if
      end tell
    on error
      return "noplaylist"
    end try
    set oldDelims to AppleScript's text item delimiters
    set AppleScript's text item delimiters to us
    set nText to n as text
    set aText to a as text
    set dText to d as text
    set AppleScript's text item delimiters to oldDelims
    return plName & rs & (ci as text) & rs & (cnt as text) & rs & (first_ as text) & rs & nText & rs & aText & rs & dText & rs & (sh as text)
    """

    private static let artworkScript = """
    on run argv
      set outPath to item 1 of argv
      set idx to (item 2 of argv) as integer
      tell application "Music"
        set raw to raw data of artwork 1 of track idx of current playlist
      end tell
      set fh to open for access (POSIX file outPath) with write permission
      try
        set eof fh to 0
        write raw to fh
      end try
      close access fh
      return "ok"
    end run
    """

    private var requestID = 0
    private var playlistName = ""
    /// Rows whose cover could not be read; not asked again within a playlist.
    private var failedArtwork = Set<String>()
    private let cache = NSCache<NSString, NSImage>()
    private let artworkQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = Metrics.artworkConcurrency
        q.qualityOfService = .utility
        return q
    }()

    init() { cache.countLimit = Metrics.artworkCacheLimit }

    /// A newer `fetch` supersedes older ones: stale completions are dropped.
    func fetch(completion: @escaping (PlaylistResult) -> Void) {
        requestID += 1
        let token = requestID
        Self.run(script: Self.fetchScript, arguments: []) { [weak self] outcome in
            guard let self, token == self.requestID else { return }
            switch outcome {
            case .denied: completion(.denied)
            case .failed: completion(.failed)
            case .output(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "notrunning" || trimmed == "noplaylist" {
                    completion(.noPlaylist)
                } else if let snap = PlaylistParser.parse(text) {
                    if snap.name != self.playlistName {
                        self.playlistName = snap.name
                        self.cache.removeAllObjects()
                        self.failedArtwork.removeAll()
                    }
                    completion(.snapshot(snap))
                } else {
                    completion(.failed)
                }
            }
        }
    }

    /// Fire-and-forget; errors are ignored (the next fetch reflects reality).
    func play(index: Int) {
        guard index >= 1 else { return }
        let script = "if application \"Music\" is running then tell application \"Music\" to play track \(index) of current playlist"
        Self.run(script: script, arguments: []) { _ in }
    }

    /// Small cover for one row (about 64px). nil when the track has no artwork or the call fails.
    func artwork(index: Int, completion: @escaping (NSImage?) -> Void) {
        let key = "\(playlistName)|\(index)" as NSString
        if let hit = cache.object(forKey: key) {
            completion(hit)
            return
        }
        if failedArtwork.contains(key as String) {
            completion(nil)
            return
        }
        artworkQueue.addOperation { [weak self] in
            let path = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("npb-art-\(UUID().uuidString).bin")
            defer { try? FileManager.default.removeItem(atPath: path) }
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            Self.runOnCurrentQueue(script: Self.artworkScript, arguments: [path, String(index)]) { outcome in
                if case .output = outcome { ok = true }
                sem.signal()
            }
            sem.wait()
            var image: NSImage?
            if ok, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: Metrics.thumbnailPixels,
                ]
                if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                    image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
            DispatchQueue.main.async {
                if let image {
                    self?.cache.setObject(image, forKey: key)
                } else {
                    self?.failedArtwork.insert(key as String)
                }
                completion(image)
            }
        }
    }

    // MARK: - osascript

    private enum Outcome {
        case output(String)
        case denied
        case failed
    }

    /// Runs on a background queue, calls back on main.
    private static func run(script: String, arguments: [String], completion: @escaping (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            runOnCurrentQueue(script: script, arguments: arguments) { outcome in
                DispatchQueue.main.async { completion(outcome) }
            }
        }
    }

    /// Blocking; call off the main thread. Same shape as NowPlayingMonitor.fetchModes.
    private static func runOnCurrentQueue(script: String, arguments: [String], completion: (Outcome) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch {
            completion(.failed)
            return
        }

        // Kill a hung osascript (e.g. a stuck permission prompt).
        let lock = NSLock()
        var timedOut = false
        DispatchQueue.global().asyncAfter(deadline: .now() + Metrics.timeout) {
            if process.isRunning {
                lock.lock(); timedOut = true; lock.unlock()
                process.terminate()
            }
        }

        // Drain stderr concurrently so neither pipe can fill and block.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()

        lock.lock(); let didTimeOut = timedOut; lock.unlock()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        if didTimeOut {
            completion(.failed)
        } else if stderr.contains("-1743") || stderr.contains("Not authorized") {
            completion(.denied)
        } else if process.terminationStatus == 0 {
            completion(.output(stdout))
        } else {
            completion(.failed)
        }
    }
}
