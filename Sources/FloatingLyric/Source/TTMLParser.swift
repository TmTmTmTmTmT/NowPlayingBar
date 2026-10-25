import Foundation

/// Parses Apple Music syllable-lyrics TTML into a `LyricsDocument`.
/// Timing comes only from `body`: `head` also holds `span`/`text` elements
/// (transliteration) whose times would run backwards if mixed in.
enum TTMLParser {
    /// `preferredLanguages` picks the translation; injectable for tests.
    static func parse(_ ttml: String,
                      preferredLanguages: [String] = Locale.preferredLanguages) -> LyricsDocument? {
        guard let data = ttml.data(using: .utf8) else { return nil }
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = false
        xml.shouldResolveExternalEntities = false
        let handler = Handler()
        handler.preferredLanguages = preferredLanguages
        xml.delegate = handler
        guard xml.parse(), !handler.failed else { return nil }
        return handler.document()
    }

    /// `ss.mmm`, `m:ss.mmm`, `h:mm:ss.mmm` (a trailing `s` is tolerated).
    static func parseTime(_ raw: String?) -> TimeInterval? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasSuffix("s") { s.removeLast() }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total: TimeInterval = 0
        for part in parts {
            guard let v = Double(part), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }
}

private final class Handler: NSObject, XMLParserDelegate {
    private struct SpanFrame {
        var begin: TimeInterval?
        var end: TimeInterval?
        var isBackground: Bool
        var text = ""
        var childCount = 0
    }

    private struct PendingLine {
        var begin: TimeInterval?
        var end: TimeInterval?
        var key: String?
        var agent: String?
        var words: [LyricWord] = []
        var background: [LyricWord] = []
        /// Text directly inside `p` (Line timing has no spans).
        var directText = ""
    }

    struct SideTable {
        var language: String?
        var texts: [String: String] = [:]
    }

    var failed = false
    var preferredLanguages: [String] = Locale.preferredLanguages

    private var timingAttr: String?
    private var language: String?
    private var lines: [LyricLine] = []
    private var sawSpan = false

    private var inHead = false
    private var inBody = false
    private var pending: PendingLine?
    private var spans: [SpanFrame] = []
    private var backgroundDepth = 0
    /// Which list the most recent word went to, for attaching tail whitespace.
    private var lastWasBackground = false

    // head side tables
    private var translations: [SideTable] = []
    private var transliterations: [SideTable] = []
    private var currentTable: (isTranslation: Bool, index: Int)?
    private var textKey: String?
    private var textBuffer = ""

    func document() -> LyricsDocument? {
        guard !lines.isEmpty else { return nil }
        let translation = Self.pickTranslation(translations, songLanguage: language,
                                           preferred: preferredLanguages)
        let transliteration = transliterations.first
        var result = lines
        for i in result.indices {
            guard let key = result[i].key else { continue }
            result[i].translation = translation?.texts[key]
            result[i].transliteration = transliteration?.texts[key]
        }
        let timing: LyricsDocument.Timing
        switch timingAttr?.lowercased() {
        case "word": timing = .word
        case "line": timing = .line
        default: timing = sawSpan ? .word : .line
        }
        return LyricsDocument(timing: timing, language: language, lines: result)
    }

    /// The first translation in one of the user's languages, in preference order.
    /// No match means no translation: a table in a language the user did not
    /// pick is noise. A translation into the song's own language is skipped too.
    static func pickTranslation(_ tables: [SideTable], songLanguage: String?,
                                preferred: [String] = Locale.preferredLanguages) -> SideTable? {
        func base(_ tag: String) -> String {
            tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? tag.lowercased()
        }
        let songBase = songLanguage.map(base)
        for pref in preferred {
            let code = base(pref)
            if code == songBase { continue }
            if let hit = tables.first(where: { $0.language.map(base) == code }) { return hit }
        }
        return nil
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failed = true }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String]) {
        switch name {
        case "tt":
            timingAttr = a["itunes:timing"]
            language = a["xml:lang"]
        case "head": inHead = true
        case "body": inBody = true
        default: break
        }
        if inHead { startHead(name, a) }
        if inBody { startBody(name, a) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if inHead { endHead(name) }
        if inBody { endBody(name) }
        switch name {
        case "head": inHead = false
        case "body": inBody = false
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inHead, textKey != nil { textBuffer += string; return }
        guard inBody, pending != nil else { return }
        if let i = spans.indices.last, spans[i].childCount == 0 {
            spans[i].text += string
        } else {
            tail(string)
        }
    }

    // MARK: head

    private func startHead(_ name: String, _ a: [String: String]) {
        switch name {
        case "translation":
            translations.append(SideTable(language: a["xml:lang"] ?? a["lang"]))
            currentTable = (true, translations.count - 1)
        case "transliteration":
            transliterations.append(SideTable(language: a["xml:lang"] ?? a["lang"]))
            currentTable = (false, transliterations.count - 1)
        case "text":
            if currentTable != nil, let key = a["for"] {
                textKey = key
                textBuffer = ""
            }
        default: break
        }
    }

    private func endHead(_ name: String) {
        switch name {
        case "translation", "transliteration":
            currentTable = nil
        case "text":
            guard let key = textKey, let table = currentTable else { return }
            let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            textKey = nil
            guard !value.isEmpty else { return }
            if table.isTranslation {
                if translations[table.index].texts[key] == nil { translations[table.index].texts[key] = value }
            } else {
                if transliterations[table.index].texts[key] == nil { transliterations[table.index].texts[key] = value }
            }
        default: break
        }
    }

    // MARK: body

    private func startBody(_ name: String, _ a: [String: String]) {
        switch name {
        case "p":
            pending = PendingLine(begin: TTMLParser.parseTime(a["begin"]),
                                  end: TTMLParser.parseTime(a["end"]),
                                  key: a["itunes:key"], agent: a["ttm:agent"])
            spans = []
            backgroundDepth = 0
        case "span":
            guard pending != nil else { return }
            sawSpan = true
            if !spans.isEmpty { spans[spans.count - 1].childCount += 1 }
            let bg = a["ttm:role"] == "x-bg"
            if bg { backgroundDepth += 1 }
            spans.append(SpanFrame(begin: TTMLParser.parseTime(a["begin"]),
                                   end: TTMLParser.parseTime(a["end"]),
                                   isBackground: bg))
        case "br":
            tail(" ")
        default: break
        }
    }

    private func endBody(_ name: String) {
        switch name {
        case "span":
            guard pending != nil, let frame = spans.popLast() else { return }
            if frame.childCount == 0 { emit(frame) }
            if frame.isBackground { backgroundDepth -= 1 }
        case "p":
            finishLine()
        default: break
        }
    }

    private func emit(_ frame: SpanFrame) {
        let trimmed = frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let hasTrailing = frame.text.last?.isWhitespace == true
        let begin = frame.begin ?? pending?.begin ?? 0
        let end = max(frame.end ?? begin, begin)
        let word = LyricWord(text: trimmed, begin: begin, end: end, trailingSpace: hasTrailing)
        if backgroundDepth > 0 {
            pending?.background.append(word)
            lastWasBackground = true
        } else {
            pending?.words.append(word)
            lastWasBackground = false
        }
    }

    /// Text outside any leaf span: whitespace here separates words.
    private func tail(_ s: String) {
        if spans.isEmpty { pending?.directText += s }
        guard s.contains(where: \.isWhitespace) else { return }
        if lastWasBackground {
            if let i = pending?.background.indices.last { pending?.background[i].trailingSpace = true }
        } else if let i = pending?.words.indices.last {
            pending?.words[i].trailingSpace = true
        }
    }

    private func finishLine() {
        guard var p = pending else { return }
        pending = nil
        spans = []
        backgroundDepth = 0
        if p.words.isEmpty && p.background.isEmpty {
            // Line timing: one word covering the whole line.
            let text = p.directText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { return }
            let b = p.begin ?? 0
            let e = max(p.end ?? b, b)
            p.words = [LyricWord(text: text, begin: b, end: e, trailingSpace: false)]
        }
        let all = p.words + p.background
        let begin = p.begin ?? all.map(\.begin).min() ?? 0
        let end = max(p.end ?? all.map(\.end).max() ?? begin, begin)
        lines.append(LyricLine(begin: begin, end: end, key: p.key, agent: p.agent,
                               words: p.words, background: p.background,
                               translation: nil, transliteration: nil))
    }
}
