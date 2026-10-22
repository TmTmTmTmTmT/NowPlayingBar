import AppKit
import Foundation

/// A snapshot of the system's "Now Playing" state, decoded from the
/// mediaremote-adapter JSON output.
struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String?
    var album: String?

    /// Bundle id of the process that *published* the media. For browser-hosted
    /// media (e.g. Safari) this is a WebKit subprocess, not the browser itself.
    var bundleIdentifier: String

    /// Bundle id of the owning application. For Safari this is `com.apple.Safari`
    /// even though `bundleIdentifier` points at the WebKit GPU subprocess.
    var parentApplicationBundleIdentifier: String?

    var isPlaying: Bool
    var isMusicApp: Bool

    /// The bundle id used for source filtering. Prefer the parent app id so that
    /// browser-hosted media is attributed to the browser (Safari/Chrome/...),
    /// not to an internal WebKit helper process.
    var sourceBundleID: String {
        if let parent = parentApplicationBundleIdentifier, !parent.isEmpty {
            return parent
        }
        return bundleIdentifier
    }
}

/// A rich snapshot for the control popover: includes artwork and timeline,
/// which the lean `NowPlayingInfo` deliberately omits (to keep the menu-bar
/// hot path cheap). Fetched on demand via a one-shot `get`.
struct NowPlayingDetail {
    var title: String
    var artist: String?
    var album: String?
    var isPlaying: Bool
    var playbackRate: Double
    var elapsedTime: Double
    var duration: Double
    /// Wall-clock time at which `elapsedTime` was sampled by the OS.
    var sampledAt: Date
    var artwork: NSImage?
    var sourceBundleID: String
    /// `false` when the snapshot was self-contradictory (half-updated by the
    /// OS right after a play/pause change) and had to be normalized; callers
    /// should re-fetch shortly to pick up the settled values.
    var isSettled: Bool = true

    /// Interpolated playback position at wall clock `now` — no IPC needed
    /// between fetches; we just advance `elapsedTime` by elapsed real time.
    func position(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        guard isPlaying, playbackRate != 0 else { return min(elapsedTime, duration) }
        let advanced = elapsedTime + now.timeIntervalSince(sampledAt) * playbackRate
        return min(max(advanced, 0), duration)
    }
}

/// Parses one line of adapter output (either a `get` payload or a `stream`
/// envelope) into a `NowPlayingInfo`. Returns `nil` when nothing is playing.
enum NowPlayingParser {
    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    /// Unwraps the `get`/`stream` envelope to the payload dict and validates
    /// the mandatory title + bundle id.
    private static func payload(from data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data),
              let top = obj as? [String: Any]
        else { return nil }
        if let type = top["type"] as? String, type == "data",
           let p = top["payload"] as? [String: Any] {
            return p
        }
        return top
    }

    /// Full snapshot incl. artwork + timeline, for the control popover.
    static func parseDetail(_ data: Data) -> NowPlayingDetail? {
        guard let p = payload(from: data),
              let title = (p["title"] as? String), !title.isEmpty,
              let bundleID = p["bundleIdentifier"] as? String
        else { return nil }

        var artwork: NSImage?
        if let b64 = p["artworkData"] as? String,
           let raw = Data(base64Encoded: b64) {
            artwork = NSImage(data: raw)
        }

        let receivedAt = Date()
        let timestamp = (p["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date()
        let playing = (p["playing"] as? Bool) ?? false
        var rate = (p["playbackRate"] as? NSNumber)?.doubleValue ?? 1
        var elapsed = (p["elapsedTime"] as? NSNumber)?.doubleValue ?? 0
        let duration = (p["duration"] as? NSNumber)?.doubleValue ?? 0
        var sampledAt = timestamp
        var settled = true

        // Right after a play/pause change the adapter briefly reports a
        // half-updated snapshot. Normalize it against the receive time.
        if !playing && rate != 0 {
            // Stale "still playing" values: freeze at the position reached now.
            let advanced = elapsed + receivedAt.timeIntervalSince(timestamp) * rate
            elapsed = duration > 0 ? min(max(advanced, 0), duration) : max(advanced, 0)
            rate = 0
            sampledAt = receivedAt
            settled = false
        } else if playing && rate == 0 {
            // Stale "paused" values: resume from the reported position.
            rate = 1
            sampledAt = receivedAt
            settled = false
        }

        let parent = p["parentApplicationBundleIdentifier"] as? String
        let source = (parent?.isEmpty == false) ? parent! : bundleID

        return NowPlayingDetail(
            title: title,
            artist: (p["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            album: (p["album"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isPlaying: playing,
            playbackRate: rate,
            elapsedTime: elapsed,
            duration: duration,
            sampledAt: sampledAt,
            artwork: artwork,
            sourceBundleID: source,
            isSettled: settled
        )
    }

    static func parse(_ data: Data) -> NowPlayingInfo? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data),
              let top = obj as? [String: Any]
        else {
            return nil
        }

        // `stream` wraps the data: {"type":"data","diff":false,"payload":{...}}
        // `get` prints the payload dictionary directly (or the literal `null`).
        let payload: [String: Any]
        if let type = top["type"] as? String, type == "data",
           let p = top["payload"] as? [String: Any] {
            payload = p
        } else {
            payload = top
        }

        // Mandatory keys per the adapter spec: bundleIdentifier, playing, title.
        guard let title = payload["title"] as? String, !title.isEmpty,
              let bundleID = payload["bundleIdentifier"] as? String
        else {
            return nil
        }

        return NowPlayingInfo(
            title: title,
            artist: (payload["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            album: (payload["album"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            bundleIdentifier: bundleID,
            parentApplicationBundleIdentifier: payload["parentApplicationBundleIdentifier"] as? String,
            isPlaying: (payload["playing"] as? Bool) ?? false,
            isMusicApp: (payload["isMusicApp"] as? Bool) ?? false
        )
    }
}

// MARK: - Playback modes (shuffle / repeat)

enum RepeatState {
    case off, one, all

    /// Cycle order: off -> all -> one -> off.
    var next: RepeatState {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

struct PlaybackModes {
    var shuffle: Bool
    var repeatMode: RepeatState

    /// Parses osascript output such as `true,off` / `false,all` / `true,one`.
    /// Returns `nil` for anything else (including `notrunning`).
    static func parse(_ output: String) -> PlaybackModes? {
        let parts = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }

        let shuffle: Bool
        switch parts[0] {
        case "true": shuffle = true
        case "false": shuffle = false
        default: return nil
        }

        let mode: RepeatState
        switch parts[1] {
        case "off": mode = .off
        case "one": mode = .one
        case "all": mode = .all
        default: return nil
        }
        return PlaybackModes(shuffle: shuffle, repeatMode: mode)
    }
}

enum ModesResult {
    case modes(PlaybackModes)
    case unsupported
    case denied
    case failed
}
