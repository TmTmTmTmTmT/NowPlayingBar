import Testing
import Foundation
@testable import FloatingLyric

/// All fixtures are synthetic; the words are meaningless on purpose.
enum Fixture {
    static let wordTTML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" \
    xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word" xml:lang="ko">
    <head><metadata>
    <iTunesMetadata>
    <translations><translation xml:lang="en"><text for="L1">tr one</text><text for="L2">tr two</text></translation></translations>
    <transliterations><transliteration xml:lang="ko-Latn">
    <text for="L1"><span begin="99.000" end="99.500">xx</span> <span begin="1.000" end="1.500">yy</span></text>
    <text for="L2">zz</text>
    </transliteration></transliterations>
    </iTunesMetadata></metadata></head>
    <body dur="1:05.000"><div begin="0.500" end="1:05.000" itunes:songPart="Verse">
    <p begin="0.500" end="2.000" itunes:key="L1" ttm:agent="v1"><span begin="0.500" end="1.000">alpha</span> <span begin="1.000" end="2.000">beta</span></p>
    <p begin="3.000" end="1:05.250" itunes:key="L2" ttm:agent="v2"><span begin="3.000" end="3.500">ga</span><span begin="3.500" end="4.000">mma</span> <span begin="4.000" end="4.500" ttm:role="x-bg">(<span begin="4.000" end="4.500">delta</span>)</span></p>
    </div></div></body></tt>
    """.replacingOccurrences(of: "</div></div>", with: "</div>")

    static let lineTTML = """
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Line" xml:lang="en">
    <head/><body><div>
    <p begin="1:02.5" end="1:05" itunes:key="L1" ttm:agent="v1">alpha   beta
    gamma</p>
    <p begin="1:00:00.000" end="1:00:03.000" itunes:key="L2">epsilon</p>
    </div></body></tt>
    """
}

struct TTMLParserTests {
    @Test func wordTimingStructure() throws {
        let doc = try #require(TTMLParser.parse(Fixture.wordTTML))
        #expect(doc.timing == .word)
        #expect(doc.language == "ko")
        #expect(doc.lines.count == 2)
        let l1 = doc.lines[0]
        #expect(l1.begin == 0.5 && l1.end == 2.0)
        #expect(l1.key == "L1" && l1.agent == "v1")
        #expect(l1.words.map(\.text) == ["alpha", "beta"])
        #expect(l1.words[0].trailingSpace)
        #expect(!l1.words[1].trailingSpace)
    }

    @Test func timeFormats() throws {
        #expect(TTMLParser.parseTime("12.345") == 12.345)
        #expect(TTMLParser.parseTime("1:05.250") == 65.25)
        #expect(TTMLParser.parseTime("1:00:03.000") == 3603)
        #expect(TTMLParser.parseTime("bogus") == nil)
        let doc = try #require(TTMLParser.parse(Fixture.wordTTML))
        #expect(doc.lines[1].end == 65.25)
    }

    @Test func syllablesWithoutSpaceStayGlued() throws {
        let line = try #require(TTMLParser.parse(Fixture.wordTTML)).lines[1]
        #expect(line.words.map(\.text) == ["ga", "mma"])
        #expect(!line.words[0].trailingSpace)
        #expect(line.words[1].trailingSpace)
    }

    @Test func backgroundAndAgents() throws {
        let doc = try #require(TTMLParser.parse(Fixture.wordTTML))
        #expect(doc.lines[1].background.map(\.text) == ["delta"])
        #expect(doc.lines[1].agent == "v2")
        #expect(doc.lines[0].background.isEmpty)
    }

    @Test func headSpansDoNotBecomeLines() throws {
        let doc = try #require(TTMLParser.parse(Fixture.wordTTML))
        #expect(doc.lines.count == 2)
        let all = doc.lines.flatMap { $0.words + $0.background }.map(\.text)
        #expect(!all.contains("xx") && !all.contains("yy") && !all.contains("zz"))
        // begins stay monotonic (head had 99.0 before 1.0)
        let begins = doc.lines.map(\.begin)
        #expect(begins == begins.sorted())
    }

    @Test func translationsAttachByKey() throws {
        let doc = try #require(TTMLParser.parse(Fixture.wordTTML, preferredLanguages: ["en-US"]))
        #expect(doc.lines[0].translation == "tr one")
        #expect(doc.lines[1].translation == "tr two")
        #expect(doc.lines[0].transliteration?.contains("xx") == true)
        #expect(doc.lines[1].transliteration == "zz")
    }

    @Test func translationNeedsMatchingLanguage() throws {
        // Fixture: song language ko, one `en` translation.
        let none = try #require(TTMLParser.parse(Fixture.wordTTML, preferredLanguages: ["ja-JP", "fr"]))
        #expect(none.lines[0].translation == nil)
        // Preference order wins, later entries are fallbacks.
        let later = try #require(TTMLParser.parse(Fixture.wordTTML, preferredLanguages: ["ja-JP", "en-GB"]))
        #expect(later.lines[0].translation == "tr one")
        // A translation into the song's own language is never shown.
        let same = try #require(TTMLParser.parse(Fixture.wordTTML, preferredLanguages: ["ko-KR"]))
        #expect(same.lines[0].translation == nil)
        // Transliteration does not depend on the user's language.
        #expect(same.lines[1].transliteration == "zz")
    }

    @Test func lineTimingMakesOneWord() throws {
        let doc = try #require(TTMLParser.parse(Fixture.lineTTML))
        #expect(doc.timing == .line)
        #expect(doc.lines.count == 2)
        let l = doc.lines[0]
        #expect(l.words.count == 1)
        #expect(l.words[0].text == "alpha beta gamma")
        #expect(l.begin == 62.5 && l.end == 65)
        #expect(l.words[0].begin == 62.5 && l.words[0].end == 65)
        #expect(doc.lines[1].begin == 3600)
    }

    @Test func malformedOrEmptyIsNil() {
        #expect(TTMLParser.parse("<tt><body><p begin=\"1\"") == nil)
        #expect(TTMLParser.parse("not xml") == nil)
        #expect(TTMLParser.parse("<tt><head/><body><div/></body></tt>") == nil)
    }

    @Test func endIsClampedToBegin() throws {
        let x = "<tt><body><div><p begin=\"5.0\" end=\"2.0\"><span begin=\"5.0\" end=\"1.0\">aa</span></p></div></body></tt>"
        let line = try #require(TTMLParser.parse(x)).lines[0]
        #expect(line.end >= line.begin)
        #expect(line.words[0].end >= line.words[0].begin)
    }
}
