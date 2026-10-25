import AppKit
import Foundation
import SQLite3
import os

private let log = Logger(subsystem: "FloatingLyric", category: "lyrics")

/// One `songs` response from Music's URL cache, reduced to what matching needs.
struct CacheCandidate {
    var name: String
    var artistName: String
    var albumName: String
    var duration: TimeInterval
    var cachedAt: Date
    var ttml: String
    var songID: String? = nil
}

/// Picks the cache entry that belongs to the playing track (PLAN §3.3 v2).
/// Artist and album are never required: storefront localization changes them
/// (`IU` vs `아이유`), while title and duration stay reliable.
enum LyricsMatcher {
    private enum Metrics {
        static let titleDurationTolerance: TimeInterval = 2
        /// `cachedAt - trackStart` range of the time path. Music prefetches the next
        /// song's response up to ~10 s before it starts, so the window leans early (FIX_GUIDE F1).
        static let timeWindow: ClosedRange<TimeInterval> = -30...10
        static let timeDurationTolerance: TimeInterval = 0.5
        /// Last resort: a single entry this close in duration (FIX_GUIDE F19).
        static let durationOnlyTolerance: TimeInterval = 0.15
    }

    static func pick(from candidates: [CacheCandidate], for track: TrackRef,
                     trackStart: Date?, launch: Date? = nil) -> CacheCandidate? {
        let title = normalize(track.title)
        guard !title.isEmpty else { return nil }
        // MediaRemote can report duration 0 right after a track starts: then
        // only the title can be checked, and the time path needs a duration.
        let durationKnown = track.duration > 0
        func delta(_ c: CacheCandidate) -> TimeInterval { abs(c.duration - track.duration) }

        var pool = candidates.filter {
            normalize($0.name) == title
                && (!durationKnown || delta($0) <= Metrics.titleDurationTolerance)
        }
        if pool.isEmpty, durationKnown, let start = trackStart {
            // Title may be localized too; the cache entry is created at playback start.
            pool = candidates.filter {
                Metrics.timeWindow.contains($0.cachedAt.timeIntervalSince(start))
                    && delta($0) <= Metrics.timeDurationTolerance
            }
        }
        if pool.isEmpty, durationKnown, let launch {
            // Title is localized and the start time is unknown: accept only an unambiguous entry.
            let close = candidates.filter {
                $0.cachedAt >= launch && delta($0) <= Metrics.durationOnlyTolerance
            }
            if close.count == 1 { return close[0] }
        }
        guard !pool.isEmpty else { return nil }

        if let album = track.album.map(normalize), !album.isEmpty {
            let hit = pool.filter { normalize($0.albumName) == album }
            if !hit.isEmpty { pool = hit }
        }
        if let artist = track.artist.map(normalize), !artist.isEmpty {
            let hit = pool.filter { normalize($0.artistName) == artist }
            if !hit.isEmpty { pool = hit }
        }
        return pool.max { $0.cachedAt < $1.cachedAt }
    }

    /// NFC, lowercase, `(feat. …)`/`[…]` removed, whitespace collapsed.
    static func normalize(_ s: String) -> String {
        var t = s.precomposedStringWithCanonicalMapping.lowercased()
        for regex in tailPatterns {
            t = regex.stringByReplacingMatches(
                in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ")
        }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let tailPatterns: [NSRegularExpression] = [
        #"[\(（]\s*(feat|ft|featuring|with|prod)\b[^\)）]*[\)）]"#,
        #"\[[^\]]*\]"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
}

extension LyricsMatcher {
    /// Number-only description of why nothing matched; never contains titles or lyrics.
    static func diagnostics(candidates: [CacheCandidate], track: TrackRef, trackStart: Date?,
                            launch: Date?) -> String {
        let title = normalize(track.title)
        let durationKnown = track.duration > 0
        let sinceLaunch = launch.map { l in candidates.filter { $0.cachedAt >= l }.count }
        let titleMatches = candidates.filter { normalize($0.name) == title }
        let minDelta = durationKnown
            ? titleMatches.map { abs($0.duration - track.duration) }.min() : nil
        let nearest = trackStart.flatMap { start in
            candidates.min { abs($0.cachedAt.timeIntervalSince(start)) < abs($1.cachedAt.timeIntervalSince(start)) }
        }
        func num(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "n/a" }
        return "no cache match: candidates=\(candidates.count)"
            + " sinceLaunch=\(sinceLaunch.map(String.init) ?? "n/a")"
            + " titleMatches=\(titleMatches.count) minDurDelta=\(num(minDelta))"
            + " nearestCachedAtMinusStart=\(num(nearest.flatMap { n in trackStart.map { n.cachedAt.timeIntervalSince($0) } }))"
            + " trackStartKnown=\(trackStart != nil)"
            + " durationKnown=\(durationKnown) source=\(track.sourceBundleID ?? "n/a")"
            + " songID=\(nearest?.songID ?? "n/a")"
    }
}

/// Outcome of one lookup. `noSessionEntries`: Music is running but has cached no
/// lyrics-bearing `songs` response since it launched, i.e. the user has not opened
/// the lyrics view in this session yet (FIX_GUIDE F1).
struct LyricsLookupResult: Equatable {
    var document: LyricsDocument?
    var noSessionEntries = false
}

/// Finds syllable lyrics in Apple Music's own URL cache (read-only) and parses
/// them. Everything slow runs on a background queue; each call supersedes the
/// previous one and a superseded call never reports back.
final class MusicCacheLyricsProvider {
    static let musicBundleID = "com.apple.Music"

    private enum Metrics {
        static let pollInterval: TimeInterval = 1
        static let giveUpAfter: TimeInterval = 20
        static let requeryInterval: TimeInterval = 1
        static let fallbackPollInterval: TimeInterval = 30
        static let memoryEntries = 50
    }

    private let cacheDirectory: URL
    private let pollInterval: TimeInterval
    private let giveUpAfter: TimeInterval
    private let requeryInterval: TimeInterval
    private let fallbackPollInterval: TimeInterval
    private let launchDate: () -> Date?
    private let completionQueue: DispatchQueue
    private let queue = DispatchQueue(label: "FloatingLyric.cache", qos: .userInitiated)

    private let lock = NSLock()
    private var token = 0
    private var current: Search?
    private var lru: [(key: String, doc: LyricsDocument)] = []
    private var loggedOnce = Set<String>()

    init(cacheDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.apple.Music"),
         pollInterval: TimeInterval = Metrics.pollInterval,
         giveUpAfter: TimeInterval = Metrics.giveUpAfter,
         requeryInterval: TimeInterval = Metrics.requeryInterval,
         fallbackPollInterval: TimeInterval = Metrics.fallbackPollInterval,
         launchDate: @escaping () -> Date? = MusicCacheLyricsProvider.musicLaunchDate,
         completionQueue: DispatchQueue = .main) {
        self.cacheDirectory = cacheDirectory
        self.pollInterval = pollInterval
        self.giveUpAfter = giveUpAfter
        self.requeryInterval = requeryInterval
        self.fallbackPollInterval = fallbackPollInterval
        self.launchDate = launchDate
        self.completionQueue = completionQueue
    }

    deinit { cancel() }

    /// When the running Music process started; nil when Music is not running.
    static func musicLaunchDate() -> Date? {
        NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID)
            .compactMap(\.launchDate).min()
    }

    /// True when no lyrics-bearing entry is newer than the Music launch (pure, for tests).
    static func hasNoSessionEntries(_ candidates: [CacheCandidate], launch: Date?) -> Bool {
        guard let launch else { return false }
        return !candidates.contains { $0.cachedAt >= launch }
    }

    /// Looks up lyrics for `track`. `trackStart` (wall clock; must be thread-safe, re-read on
    /// every attempt) enables the
    /// time-based fallback match. `completion` runs on the main queue and may run
    /// twice: first with the 20 s give-up result, later when the cache finally gets
    /// an entry (or the no-session hint changes). A newer call or `cancel()` ends it.
    func lyrics(for track: TrackRef, trackStart: @escaping () -> Date?,
                completion: @escaping (LyricsLookupResult) -> Void) {
        lock.lock()
        token += 1
        let myToken = token
        let previous = current
        current = nil
        let cached = cachedDocument(for: track)
        lock.unlock()
        previous?.stop()

        guard track.sourceBundleID == Self.musicBundleID else {
            deliver(LyricsLookupResult(document: nil), token: myToken, completion)
            return
        }
        if let cached {
            deliver(LyricsLookupResult(document: cached), token: myToken, completion)
            return
        }
        let search = Search(provider: self, track: track, trackStart: trackStart,
                            token: myToken, completion: completion)
        lock.lock()
        if token == myToken { current = search } else { lock.unlock(); return }
        lock.unlock()
        queue.async { search.start() }
    }

    /// Drops the pending lookup without calling its completion.
    func cancel() {
        lock.lock()
        token += 1
        let previous = current
        current = nil
        lock.unlock()
        previous?.stop()
    }

    // MARK: delivery & memory cache

    fileprivate func deliver(_ result: LyricsLookupResult, token t: Int,
                             _ completion: @escaping (LyricsLookupResult) -> Void) {
        completionQueue.async { [weak self] in
            // Re-check on the delivery queue so a late supersede still wins.
            guard let self, self.isCurrent(t) else { return }
            completion(result)
        }
    }

    fileprivate func clearCurrent(_ t: Int) {
        lock.lock(); defer { lock.unlock() }
        if token == t { current = nil }
    }

    fileprivate func isCurrent(_ t: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == t
    }

    private static func memoryKey(_ track: TrackRef) -> String {
        let n = LyricsMatcher.normalize
        return "\(n(track.title))|\(n(track.artist ?? ""))|\(Int(track.duration.rounded()))"
    }

    /// Caller holds `lock`.
    private func cachedDocument(for track: TrackRef) -> LyricsDocument? {
        let key = Self.memoryKey(track)
        guard let i = lru.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = lru.remove(at: i)
        lru.append(entry)
        return entry.doc
    }

    fileprivate func remember(_ doc: LyricsDocument, for track: TrackRef) {
        lock.lock(); defer { lock.unlock() }
        let key = Self.memoryKey(track)
        lru.removeAll { $0.key == key }
        lru.append((key, doc))
        if lru.count > Metrics.memoryEntries { lru.removeFirst(lru.count - Metrics.memoryEntries) }
    }

    /// Logs a message once per (kind, track) so retries do not spam.
    fileprivate func logOnce(_ kind: String, track: TrackRef, _ message: @autoclosure () -> String) {
        let key = kind + "|" + Self.memoryKey(track)
        lock.lock()
        let first = loggedOnce.insert(key).inserted
        if loggedOnce.count > 200 { loggedOnce.removeAll() }
        lock.unlock()
        if first { let m = message(); log.notice("\(m, privacy: .public)") }
    }

    // MARK: search

    /// One lookup: polls the cache each second for `giveUpAfter`, re-queries on WAL
    /// writes, and after giving up keeps only the WAL watcher (throttled; 30 s poll when
    /// there is no WAL file) until it finds the lyrics or is stopped.
    /// All members except `stop()` run on the provider queue.
    private final class Search {
        private let provider: MusicCacheLyricsProvider
        private let track: TrackRef
        private let trackStart: () -> Date?
        private let token: Int
        private let completion: (LyricsLookupResult) -> Void
        private var timer: DispatchSourceTimer?
        private var watcher: DispatchSourceFileSystemObject?
        private var fallback: DispatchSourceTimer?
        private var deadline = Date()
        private var finished = false
        private var gaveUp = false
        private var startedAt = Date()
        private var lastNoSession = false
        private var lastQuery = Date.distantPast
        private var requeryPending = false
        /// entry_ID -> parsed row (nil = unusable), so retries only parse new rows.
        private var memo: [Int64: CacheCandidate?] = [:]
        private let stateLock = NSLock()
        private var stopped = false

        init(provider: MusicCacheLyricsProvider, track: TrackRef, trackStart: @escaping () -> Date?,
             token: Int, completion: @escaping (LyricsLookupResult) -> Void) {
            self.provider = provider
            self.track = track
            self.trackStart = trackStart
            self.token = token
            self.completion = completion
        }

        func start() {
            startedAt = Date()
            deadline = startedAt.addingTimeInterval(provider.giveUpAfter)
            guard !isStopped else { return }
            let t = DispatchSource.makeTimerSource(queue: provider.queue)
            t.schedule(deadline: .now(), repeating: provider.pollInterval)
            t.setEventHandler { [weak self] in self?.attempt() }
            timer = t
            t.resume()
            watchWAL()
        }

        func stop() {
            stateLock.lock(); stopped = true; stateLock.unlock()
            provider.queue.async { [self] in teardown() }
        }

        private var isStopped: Bool {
            stateLock.lock(); defer { stateLock.unlock() }
            return stopped
        }

        private func teardown() {
            timer?.cancel(); timer = nil
            fallback?.cancel(); fallback = nil
            watcher?.cancel(); watcher = nil
            provider.clearCurrent(token)   // breaks the provider <-> search cycle
        }

        /// A write to the WAL means Music just cached something; look now.
        private func watchWAL() {
            guard watcher == nil else { return }
            let path = provider.cacheDirectory.appendingPathComponent("Cache.db-wal").path
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { return }
            let w = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: provider.queue)
            w.setEventHandler { [weak self, weak w] in
                guard let self else { return }
                if let w, !w.data.isDisjoint(with: [.delete, .rename]) {
                    // The WAL was replaced: the descriptor is stale. Re-open via the slow poll.
                    self.watcher?.cancel(); self.watcher = nil
                    if self.gaveUp { self.startFallbackIfNeeded() }
                    return
                }
                self.walChanged()
            }
            w.setCancelHandler { close(fd) }
            watcher = w
            w.resume()
        }

        /// During polling a write means look now; after giving up, at most once per `requeryInterval`.
        private func walChanged() {
            guard gaveUp else { attempt(); return }
            guard !requeryPending else { return }
            let wait = max(provider.requeryInterval - Date().timeIntervalSince(lastQuery), 0)
            requeryPending = true
            provider.queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.requeryPending = false
                self.attempt()
            }
        }

        /// No WAL to watch: look every `fallbackPollInterval` and retry opening the WAL.
        private func startFallbackIfNeeded() {
            guard watcher == nil, fallback == nil, !isStopped else { return }
            let t = DispatchSource.makeTimerSource(queue: provider.queue)
            t.schedule(deadline: .now() + provider.fallbackPollInterval, repeating: provider.fallbackPollInterval)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.watchWAL()
                if self.watcher != nil { self.fallback?.cancel(); self.fallback = nil }
                self.attempt()
            }
            fallback = t
            t.resume()
        }

        private func attempt() {
            guard !finished, !isStopped, provider.isCurrent(token) else { teardown(); return }
            lastQuery = Date()
            let candidates = loadCandidates()
            let start = trackStart()
            if let hit = LyricsMatcher.pick(from: candidates, for: track, trackStart: start,
                                            launch: provider.launchDate()) {
                if gaveUp {
                    let n = Int(Date().timeIntervalSince(startedAt).rounded())
                    provider.logOnce("late", track: track, "late match after \(n) s")
                }
                finish(with: hit)
                return
            }
            let noSession = MusicCacheLyricsProvider.hasNoSessionEntries(
                candidates, launch: provider.launchDate())
            if !gaveUp {
                guard Date() >= deadline else { return }
                let diag = LyricsMatcher.diagnostics(
                    candidates: candidates, track: track, trackStart: start, launch: provider.launchDate())
                provider.logOnce("nomatch", track: track, "\(diag) noSession=\(noSession)")
                gaveUp = true
                timer?.cancel(); timer = nil     // polling ends; the watcher stays
                lastNoSession = noSession
                provider.deliver(LyricsLookupResult(document: nil, noSessionEntries: noSession),
                                 token: token, completion)
                startFallbackIfNeeded()
            } else if noSession != lastNoSession {
                lastNoSession = noSession
                provider.deliver(LyricsLookupResult(document: nil, noSessionEntries: noSession),
                                 token: token, completion)
            }
        }

        private func finish(with hit: CacheCandidate) {
            finished = true
            teardown()
            var doc = TTMLParser.parse(hit.ttml)
            doc?.songID = hit.songID
            if let doc {
                provider.remember(doc, for: track)
                provider.logOnce("ok", track: track,
                                 "lyrics ready: \(doc.lines.count) lines, \(doc.timing)")
            } else {
                provider.logOnce("parse", track: track,
                                 "TTML parse failed: songID=\(hit.songID ?? "n/a") ttmlLength=\(hit.ttml.count)")
            }
            provider.deliver(LyricsLookupResult(document: doc), token: token, completion)
        }

        // MARK: SQLite

        private func loadCandidates() -> [CacheCandidate] {
            let dir = provider.cacheDirectory
            var db: OpaquePointer?
            let path = dir.appendingPathComponent("Cache.db").path
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
                sqlite3_close(db)
                provider.logOnce("open", track: track, "cache db unavailable")
                return []
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 200)

            let sql = """
                SELECT r.entry_ID, r.time_stamp, d.isDataOnFS, d.receiver_data \
                FROM cfurl_cache_response r JOIN cfurl_cache_receiver_data d USING(entry_ID) \
                WHERE r.request_key LIKE '%/v1/catalog/%/songs%' ORDER BY r.time_stamp DESC
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                sqlite3_finalize(stmt)
                provider.logOnce("schema", track: track, "cache schema unexpected")
                return []
            }
            defer { sqlite3_finalize(stmt) }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

            var result: [CacheCandidate] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                if let known = memo[id] {
                    if let known { result.append(known) }
                    continue
                }
                var parsed: CacheCandidate?
                if let stamp = sqlite3_column_text(stmt, 1),
                   let date = formatter.date(from: String(cString: stamp)),
                   let body = Self.body(stmt, dir: dir) {
                    parsed = Self.candidate(json: body, cachedAt: date)
                }
                memo[id] = .some(parsed)
                if let parsed { result.append(parsed) }
            }
            return result
        }

        private static func body(_ stmt: OpaquePointer, dir: URL) -> Data? {
            let onFS = sqlite3_column_int(stmt, 2) != 0
            let count = Int(sqlite3_column_bytes(stmt, 3))
            guard count > 0, let raw = sqlite3_column_blob(stmt, 3) else { return nil }
            let blob = Data(bytes: raw, count: count)
            guard onFS else { return blob }
            guard let name = String(data: blob, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, !name.contains("/") else { return nil }
            return try? Data(contentsOf: dir.appendingPathComponent("fsCachedData")
                .appendingPathComponent(name))
        }

        /// Catalog ids are strings in the API but may arrive as numbers.
        private static func stringID(_ value: Any?) -> String? {
            if let s = value as? String, !s.isEmpty { return s }
            if let n = value as? NSNumber { return n.stringValue }
            return nil
        }

        private static func candidate(json: Data, cachedAt: Date) -> CacheCandidate? {
            guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let song = (root["data"] as? [[String: Any]])?.first,
                  let attrs = song["attributes"] as? [String: Any],
                  let name = attrs["name"] as? String,
                  let millis = (attrs["durationInMillis"] as? NSNumber)?.doubleValue,
                  let rel = song["relationships"] as? [String: Any],
                  let lyric = rel["syllable-lyrics"] as? [String: Any],
                  let first = (lyric["data"] as? [[String: Any]])?.first,
                  let lyricAttrs = first["attributes"] as? [String: Any],
                  let ttml = (lyricAttrs["ttmlLocalizations"] as? String) ?? (lyricAttrs["ttml"] as? String),
                  !ttml.isEmpty
            else { return nil }
            return CacheCandidate(name: name,
                                  artistName: attrs["artistName"] as? String ?? "",
                                  albumName: attrs["albumName"] as? String ?? "",
                                  duration: millis / 1000, cachedAt: cachedAt, ttml: ttml,
                                  songID: Self.stringID(song["id"]))
        }
    }
}
