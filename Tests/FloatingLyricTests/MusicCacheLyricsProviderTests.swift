import Testing
import Foundation
import SQLite3
@testable import FloatingLyric

/// Builds a throwaway Music-style cache directory (Cache.db + fsCachedData).
private final class FakeCache {
    let dir: URL
    private var db: OpaquePointer?
    private var nextID: Int32 = 1

    init(wal: Bool = false) throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloatingLyricTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("fsCachedData"), withIntermediateDirectories: true)
        #expect(sqlite3_open(dir.appendingPathComponent("Cache.db").path, &db) == SQLITE_OK)
        if wal { exec("PRAGMA journal_mode=WAL") }
        exec("CREATE TABLE cfurl_cache_response (entry_ID INTEGER PRIMARY KEY, request_key TEXT, time_stamp TEXT)")
        exec("CREATE TABLE cfurl_cache_receiver_data (entry_ID INTEGER PRIMARY KEY, isDataOnFS INTEGER, receiver_data BLOB)")
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: dir)
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    static func json(name: String, artist: String, duration: Int, ttml: String, traits: [String]? = nil) -> String {
        var attrs: [String: Any] = ["name": name, "artistName": artist, "albumName": "Album", "durationInMillis": duration]
        if let traits { attrs["audioTraits"] = traits }
        let obj: [String: Any] = ["data": [[
            "id": "1234567",
            "attributes": attrs,
            "relationships": ["syllable-lyrics": ["data": [["attributes": ["ttmlLocalizations": ttml]]]]],
        ]]]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    func add(json: String, onFS: Bool, key: String = "https://x/v1/catalog/kr/songs?filter=1",
             stamp: String = "2026-10-23 12:00:00") throws {
        let id = nextID; nextID += 1
        let blob: Data
        if onFS {
            let name = UUID().uuidString
            try json.write(to: dir.appendingPathComponent("fsCachedData/\(name)"), atomically: true, encoding: .utf8)
            blob = Data(name.utf8)
        } else {
            blob = Data(json.utf8)
        }
        exec("INSERT INTO cfurl_cache_response VALUES (\(id), '\(key)', '\(stamp)')")
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO cfurl_cache_receiver_data VALUES (?, ?, ?)", -1, &stmt, nil)
        sqlite3_bind_int(stmt, 1, id)
        sqlite3_bind_int(stmt, 2, onFS ? 1 : 0)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }
}

private func track(_ title: String, source: String = "com.apple.Music") -> TrackRef {
    TrackRef(title: title, artist: "A", album: nil, duration: 200, sourceBundleID: source)
}

private let queue = DispatchQueue(label: "test.completion")

private func fetch(_ provider: MusicCacheLyricsProvider, _ t: TrackRef) async -> LyricsDocument? {
    await withCheckedContinuation { c in
        provider.lyrics(for: t, trackStart: { nil }) { c.resume(returning: $0.document) }
    }
}

/// Collects every delivery of one lookup (a lookup can report more than once).
private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LyricsLookupResult] = []
    func add(_ r: LyricsLookupResult) { lock.lock(); items.append(r); lock.unlock() }
    var all: [LyricsLookupResult] { lock.lock(); defer { lock.unlock() }; return items }

    /// Waits up to `seconds` for `count` deliveries.
    func wait(count: Int, seconds: TimeInterval = 5) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if all.count >= count { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return all.count >= count
    }
}

private func startLookup(_ provider: MusicCacheLyricsProvider, _ t: TrackRef) -> Results {
    let r = Results()
    provider.lyrics(for: t, trackStart: { nil }) { r.add($0) }
    return r
}

private let oldStamp = "2026-10-23 12:00:00"
private let launchAfter = ISO8601DateFormatter().date(from: "2026-10-24T00:00:00Z")!   // later than oldStamp


struct MusicCacheLyricsProviderTests {
    @Test(arguments: [(["atmos", "lossless"], true), (["lossless"], false), (nil, false)] as [([String]?, Bool)])
    func atmosTraitSetsIsAtmos(traits: [String]?, expected: Bool) async throws {
        let cache = try FakeCache()
        try cache.add(json: FakeCache.json(name: "Song", artist: "A", duration: 200_000, ttml: Fixture.wordTTML, traits: traits), onFS: false)
        let provider = MusicCacheLyricsProvider(cacheDirectory: cache.dir, pollInterval: 0.05,
                                                giveUpAfter: 1, completionQueue: queue)
        let doc = await fetch(provider, track("Song"))
        #expect(doc?.isAtmos == expected)
    }

    @Test(arguments: [true, false])
    func findsLyricsInFileOrBlob(onFS: Bool) async throws {
        let cache = try FakeCache()
        try cache.add(json: FakeCache.json(name: "Other", artist: "A", duration: 100_000, ttml: Fixture.lineTTML), onFS: onFS)
        try cache.add(json: FakeCache.json(name: "Song", artist: "A", duration: 200_000, ttml: Fixture.wordTTML), onFS: onFS)
        try cache.add(json: "not json", onFS: onFS)
        let provider = MusicCacheLyricsProvider(cacheDirectory: cache.dir, pollInterval: 0.05,
                                                giveUpAfter: 1, completionQueue: queue)
        let doc = await fetch(provider, track("Song"))
        #expect(doc?.timing == .word)
        #expect(doc?.songID == "1234567")
        #expect(doc?.lines.count == 2)
        // second call is served from memory even if the cache disappears
        try? FileManager.default.removeItem(at: cache.dir.appendingPathComponent("Cache.db"))
        let again = await fetch(provider, track("Song"))
        #expect(again == doc)
    }

    @Test func otherSourceReturnsNil() async throws {
        let cache = try FakeCache()
        try cache.add(json: FakeCache.json(name: "Song", artist: "A", duration: 200_000, ttml: Fixture.wordTTML), onFS: true)
        let provider = MusicCacheLyricsProvider(cacheDirectory: cache.dir, pollInterval: 0.05,
                                                giveUpAfter: 1, completionQueue: queue)
        let doc = await fetch(provider, track("Song", source: "com.spotify.client"))
        #expect(doc == nil)
    }

    @Test func noMatchGivesNilAfterTimeout() async throws {
        let cache = try FakeCache()
        let provider = MusicCacheLyricsProvider(cacheDirectory: cache.dir, pollInterval: 0.05,
                                                giveUpAfter: 0.3, completionQueue: queue)
        #expect(await fetch(provider, track("Missing")) == nil)
    }

    @Test func entryAppearingLaterIsFound() async throws {
        let cache = try FakeCache()
        let provider = MusicCacheLyricsProvider(cacheDirectory: cache.dir, pollInterval: 0.05,
                                                giveUpAfter: 3, completionQueue: queue)
        async let result = fetch(provider, track("Song"))
        try await Task.sleep(nanoseconds: 300_000_000)
        try cache.add(json: FakeCache.json(name: "Song", artist: "A", duration: 200_000, ttml: Fixture.wordTTML), onFS: true)
        #expect(await result != nil)
    }

    @Test func watcherSurvivesGiveUpAndFindsLaterEntry() async throws {
        let cache = try FakeCache(wal: true)
        try cache.add(json: FakeCache.json(name: "Other", artist: "A", duration: 100_000, ttml: Fixture.lineTTML), onFS: true)
        let provider = MusicCacheLyricsProvider(cacheDirectory: cache.dir, pollInterval: 0.05, giveUpAfter: 0.3,
                                                requeryInterval: 0.05, fallbackPollInterval: 60,
                                                launchDate: { nil }, completionQueue: queue)
        let results = startLookup(provider, track("Song"))
        #expect(await results.wait(count: 1))
        #expect(results.all[0].document == nil)
        try await Task.sleep(nanoseconds: 300_000_000)           // well past give-up
        try cache.add(json: FakeCache.json(name: "Song", artist: "A", duration: 200_000, ttml: Fixture.wordTTML), onFS: true)
        #expect(await results.wait(count: 2))
        #expect(results.all[1].document?.timing == .word)
    }

    @Test func fallbackPollFindsEntryWithoutWAL() async throws {
        let cache = try FakeCache(wal: false)                   // rollback journal: no -wal file
        let provider = MusicCacheLyricsProvider(cacheDirectory: cache.dir, pollInterval: 0.05, giveUpAfter: 0.2,
                                                requeryInterval: 0.05, fallbackPollInterval: 0.2,
                                                launchDate: { nil }, completionQueue: queue)
        let results = startLookup(provider, track("Song"))
        #expect(await results.wait(count: 1))
        try cache.add(json: FakeCache.json(name: "Song", artist: "A", duration: 200_000, ttml: Fixture.lineTTML), onFS: true)
        #expect(await results.wait(count: 2))
        #expect(results.all[1].document?.timing == .line)
    }

    @Test func newTrackStopsTheLingeringWatcher() async throws {
        let cache = try FakeCache(wal: true)
        let provider = MusicCacheLyricsProvider(cacheDirectory: cache.dir, pollInterval: 0.05, giveUpAfter: 0.2,
                                                requeryInterval: 0.05, launchDate: { nil }, completionQueue: queue)
        let first = startLookup(provider, track("First"))
        #expect(await first.wait(count: 1))
        let second = startLookup(provider, track("Second"))
        #expect(await second.wait(count: 1))
        try cache.add(json: FakeCache.json(name: "First", artist: "A", duration: 200_000, ttml: Fixture.lineTTML), onFS: true)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(first.all.count == 1)                           // superseded: silent
        #expect(second.all.count == 1)                          // "First" is not "Second"
    }

    @Test func sessionFlagFollowsLaunchDate() async throws {
        // Only entries older than the launch: Music has not cached lyrics this session.
        let cache = try FakeCache(wal: true)
        try cache.add(json: FakeCache.json(name: "Other", artist: "A", duration: 100_000, ttml: Fixture.lineTTML),
                      onFS: true, stamp: oldStamp)
        let provider = MusicCacheLyricsProvider(cacheDirectory: cache.dir, pollInterval: 0.05, giveUpAfter: 0.2,
                                                requeryInterval: 0.05, launchDate: { launchAfter }, completionQueue: queue)
        let results = startLookup(provider, track("Song"))
        #expect(await results.wait(count: 1))
        #expect(results.all[0].document == nil)
        #expect(results.all[0].noSessionEntries)
        // The user opens lyrics in Music: a fresh entry (other song) clears the hint.
        try cache.add(json: FakeCache.json(name: "Another", artist: "A", duration: 150_000, ttml: Fixture.lineTTML),
                      onFS: true, stamp: "2030-01-01 00:00:00")
        #expect(await results.wait(count: 2))
        #expect(results.all[1].document == nil)
        #expect(results.all[1].noSessionEntries == false)
    }

    @Test func noFlagWhenMusicNotRunningOrEntriesAreNewer() async throws {
        let cache = try FakeCache()
        let provider = MusicCacheLyricsProvider(cacheDirectory: cache.dir, pollInterval: 0.05, giveUpAfter: 0.2,
                                                launchDate: { nil }, completionQueue: queue)
        let results = startLookup(provider, track("Song"))
        #expect(await results.wait(count: 1))
        #expect(results.all[0].noSessionEntries == false)
    }

    @Test func sessionDetectionIsPure() {
        func cand(_ at: Date) -> CacheCandidate {
            CacheCandidate(name: "x", artistName: "", albumName: "", duration: 1, cachedAt: at, ttml: "")
        }
        let launch = Date(timeIntervalSince1970: 1_000)
        let h = MusicCacheLyricsProvider.hasNoSessionEntries
        #expect(h([], launch) == true)
        #expect(h([cand(Date(timeIntervalSince1970: 999))], launch) == true)
        #expect(h([cand(Date(timeIntervalSince1970: 1_000))], launch) == false)
        #expect(h([cand(Date(timeIntervalSince1970: 500)), cand(Date(timeIntervalSince1970: 2_000))], launch) == false)
        #expect(h([], nil) == false)
    }

    @Test func trackStartReReadOnEveryAttempt() async throws {
        let cache = try FakeCache()
        let stamp = "2026-10-23 12:00:00"
        let cachedAt = ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z")!
        // Same duration twice: only the time path can tell them apart.
        try cache.add(json: FakeCache.json(name: "Localized", artist: "A", duration: 200_000, ttml: Fixture.wordTTML),
                      onFS: true, stamp: stamp)
        try cache.add(json: FakeCache.json(name: "Localized2", artist: "A", duration: 200_000, ttml: Fixture.lineTTML),
                      onFS: true, stamp: "2026-10-23 13:00:00")
        let provider = MusicCacheLyricsProvider(cacheDirectory: cache.dir, pollInterval: 0.05,
                                                giveUpAfter: 3, launchDate: { Date(timeIntervalSince1970: 0) },
                                                completionQueue: queue)
        let calls = CallCounter()
        let r = Results()
        provider.lyrics(for: track("Titel"), trackStart: { calls.next() >= 3 ? cachedAt : nil }) { r.add($0) }
        #expect(await r.wait(count: 1))
        #expect(r.all.first?.document?.timing == .word)
        #expect(calls.value >= 3)
    }

    @Test func durationOnlyDoesNotMatchStaleSingleCandidate() async throws {
        let cache = try FakeCache()
        try cache.add(json: FakeCache.json(name: "Localized", artist: "A", duration: 200_100, ttml: Fixture.wordTTML),
                      onFS: true, stamp: "2026-10-23 12:00:00")
        let start = ISO8601DateFormatter().date(from: "2026-10-23T12:40:00Z")!
        for known in [false, true] {
            let provider = MusicCacheLyricsProvider(cacheDirectory: cache.dir, pollInterval: 0.05,
                                                    giveUpAfter: 0.3, launchDate: { Date(timeIntervalSince1970: 0) },
                                                    completionQueue: queue)
            let r = Results()
            provider.lyrics(for: track("Titel"), trackStart: { known ? start : nil }) { r.add($0) }
            #expect(await r.wait(count: 1))
            #expect(r.all.first?.document == nil)
        }
    }

    @Test func durationOnlyRejectsTwoCandidates() async throws {
        let cache = try FakeCache()
        try cache.add(json: FakeCache.json(name: "L1", artist: "A", duration: 200_060, ttml: Fixture.wordTTML), onFS: true)
        try cache.add(json: FakeCache.json(name: "L2", artist: "A", duration: 199_900, ttml: Fixture.lineTTML), onFS: true)
        let provider = MusicCacheLyricsProvider(cacheDirectory: cache.dir, pollInterval: 0.05,
                                                giveUpAfter: 0.3, launchDate: { Date(timeIntervalSince1970: 0) },
                                                completionQueue: queue)
        #expect(await fetch(provider, track("Titel")) == nil)
    }

    @Test func supersededRequestIsDropped() async throws {
        let cache = try FakeCache()
        try cache.add(json: FakeCache.json(name: "Second", artist: "A", duration: 200_000, ttml: Fixture.lineTTML), onFS: true)
        let provider = MusicCacheLyricsProvider(cacheDirectory: cache.dir, pollInterval: 0.05,
                                                giveUpAfter: 1, completionQueue: queue)
        let firstCalled = Box()
        provider.lyrics(for: track("First"), trackStart: { nil }) { _ in firstCalled.set() }
        let doc = await fetch(provider, track("Second"))
        #expect(doc?.timing == .line)
        try await Task.sleep(nanoseconds: 1_300_000_000)   // past First's give-up time
        #expect(!firstCalled.value)
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
