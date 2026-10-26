import Foundation

/// One syllable or word. `trailingSpace` records whether the source had
/// whitespace after it, because Korean syllable spans often touch each other.
struct LyricWord: Equatable {
    var text: String
    var begin: TimeInterval
    var end: TimeInterval
    var trailingSpace: Bool
}

/// A sung line. `key` is the TTML `itunes:key` that translations point at.
struct LyricLine: Equatable {
    var begin: TimeInterval
    var end: TimeInterval
    var key: String?
    /// `v1`, `v2`, ... Duets alternate agents.
    var agent: String?
    var words: [LyricWord]
    /// Background vocals (`ttm:role="x-bg"`), shown smaller under the line.
    var background: [LyricWord]
    var translation: String?
    var transliteration: String?
}

/// Parsed lyrics. Lives in memory only; never written to disk.
struct LyricsDocument: Equatable {
    enum Timing: Equatable {
        case word, line, none
    }

    var timing: Timing
    var language: String?
    var lines: [LyricLine]
    /// Catalog id of the song the lyrics belong to; the only id that is logged.
    var songID: String? = nil
    /// The song has a Dolby Atmos version (catalog `audioTraits`): its playback lags the reported position.
    var isAtmos: Bool = false
}
