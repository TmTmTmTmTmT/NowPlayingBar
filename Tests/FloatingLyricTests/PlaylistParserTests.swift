import Testing
@testable import FloatingLyric

struct PlaylistParserTests {
    private let rs = "\u{1E}"
    private let us = "\u{1F}"

    private func make(name: String = "My List", current: String = "2",
                      total: Int? = nil, first: Int = 1,
                      titles: [String], artists: [String], durations: [String], shuffle: String = "false") -> String {
        [name, current, String(total ?? titles.count), String(first),
         titles.joined(separator: us), artists.joined(separator: us),
         durations.joined(separator: us), shuffle].joined(separator: rs) + "\n"
    }

    @Test func normal() {
        let out = make(titles: ["Track One", "Track Two", "Track Three"],
                       artists: ["Artist A", "Artist B", "Artist A"],
                       durations: ["193.615", "200", "61.5"])
        let s = PlaylistParser.parse(out)
        #expect(s?.name == "My List")
        #expect(s?.tracks.count == 3)
        #expect(s?.currentIndex == 2)
        #expect(s?.tracks[0] == PlaylistTrack(index: 1, title: "Track One", artist: "Artist A", duration: 193.615))
        #expect(s?.tracks[2].index == 3)
        #expect(s?.totalCount == 3)
        #expect(s?.firstIndex == 1)
        #expect(s?.isTruncated == false)
    }

    @Test func windowKeepsAbsoluteIndexes() {
        // Rows 501–503 of a 2000-row playlist; the current track is row 502.
        let out = make(current: "502", total: 2000, first: 501,
                       titles: ["Track One", "Track Two", "Track Three"],
                       artists: ["A", "B", "C"], durations: ["1", "2", "3"])
        let s = PlaylistParser.parse(out)
        #expect(s?.tracks.map(\.index) == [501, 502, 503])
        #expect(s?.currentIndex == 502)
        #expect(s?.totalCount == 2000)
        #expect(s?.firstIndex == 501)
        #expect(s?.isTruncated == true)
    }

    @Test func currentOutsideWindowIsNil() {
        let out = make(current: "10", total: 2000, first: 501,
                       titles: ["Track One"], artists: ["A"], durations: ["1"])
        #expect(PlaylistParser.parse(out)?.currentIndex == nil)
    }

    @Test func badTotalOrFirstIsGarbage() {
        let out = ["L", "1", "x", "1", "T", "A", "1", "false"].joined(separator: rs)
        #expect(PlaylistParser.parse(out) == nil)
        let out2 = ["L", "1", "5", "0", "T", "A", "1", "false"].joined(separator: rs)
        #expect(PlaylistParser.parse(out2) == nil)
    }

    @Test(arguments: [
        (total: 0, current: 0, expected: (1, 0)),
        (total: 236, current: 198, expected: (1, 236)),
        (total: 1000, current: 5, expected: (1, 1000)),
        (total: 1001, current: 1, expected: (1, 1000)),
        (total: 2000, current: 1000, expected: (700, 1699)),
        (total: 2000, current: 1990, expected: (1001, 2000)),
        (total: 2000, current: 0, expected: (1, 1000)),
        (total: 2000, current: 5000, expected: (1001, 2000)),
    ])
    func windowArithmetic(_ c: (total: Int, current: Int, expected: (Int, Int))) {
        let w = PlaylistParser.window(total: c.total, current: c.current == 0 ? nil : c.current)
        #expect(w.first == c.expected.0)
        #expect(w.last == c.expected.1)
    }

    @Test func decimalCommaDurations() {
        let out = make(titles: ["Track One", "Track Two"], artists: ["A", "B"], durations: ["193,615", "5,5"])
        let s = PlaylistParser.parse(out)
        #expect(s?.tracks[0].duration == 193.615)
        #expect(s?.tracks[1].duration == 5.5)
    }

    @Test func emptyPlaylist() {
        let out = ["Empty", "0", "0", "1", "", "", "", "false"].joined(separator: rs) + "\n"
        let s = PlaylistParser.parse(out)
        #expect(s?.tracks.isEmpty == true)
        #expect(s?.currentIndex == nil)
        #expect(s?.name == "Empty")
    }

    @Test func currentIndexMissingOrZero() {
        for cur in ["0", "", "abc", "9"] {  // "9" is outside the 2-row window
            let out = make(current: cur, titles: ["Track One", "Track Two"], artists: ["A", "B"], durations: ["1", "2"])
            #expect(PlaylistParser.parse(out)?.currentIndex == nil)
        }
    }

    @Test func awkwardTitles() {
        let titles = ["He said \"Hi\", ok", "Tab\there", "It's, fine"]
        let out = make(titles: titles, artists: ["A, B", "C\t D", "E"], durations: ["1", "2", "3"])
        let s = PlaylistParser.parse(out)
        #expect(s?.tracks.map(\.title) == titles)
        #expect(s?.tracks[0].artist == "A, B")
        #expect(s?.tracks[1].artist == "C\t D")
    }

    @Test func emptyArtistKept() {
        let out = make(titles: ["Track One", "Track Two"], artists: ["", "B"], durations: ["1", "2"])
        #expect(PlaylistParser.parse(out)?.tracks.map(\.artist) == ["", "B"])
    }

    @Test func shuffleFlag() {
        let on = make(titles: ["Track One"], artists: ["A"], durations: ["1"], shuffle: "true")
        #expect(PlaylistParser.parse(on)?.shuffleEnabled == true)
        let off = make(titles: ["Track One"], artists: ["A"], durations: ["1"])
        #expect(PlaylistParser.parse(off)?.shuffleEnabled == false)
        // The old seven-section layout is no longer accepted.
        let old = ["L", "1", "1", "1", "T", "A", "1"].joined(separator: rs)
        #expect(PlaylistParser.parse(old) == nil)
    }

    @Test func garbage() {
        #expect(PlaylistParser.parse("") == nil)
        #expect(PlaylistParser.parse("hello world") == nil)
        #expect(PlaylistParser.parse("notrunning") == nil)
        // Mismatched list lengths.
        let bad = make(titles: ["Track One", "Track Two"], artists: ["A"], durations: ["1", "2"])
        #expect(PlaylistParser.parse(bad) == nil)
    }
}
