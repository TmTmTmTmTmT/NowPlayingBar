import CoreGraphics

/// HDR highlight decision and colors (PLAN 4.1 v5, F8). The colors go on a solid layer
/// that is masked by the glyph alpha, the same path as the host's `HighlightButton`.
enum LyricHDR {
    enum Metrics {
        /// Standard mode: filled part of the current line, in multiples of SDR white.
        static let fillMultiplier: CGFloat = 1.03
        /// Emphasis peak for the weakest (s = 0) and the strongest (s = 1) group.
        static let peakMin: CGFloat = 1.15
        static let peakMax: CGFloat = 1.6
    }

    /// Headroom to use, or nil for SDR. Capped by what the screen can ever show: its current
    /// headroom only rises once EDR content is on screen, so it would block the first frames.
    static func headroom(isDark: Bool, potential: CGFloat, target: CGFloat) -> CGFloat? {
        guard isDark, potential > 1, target > 1, potential.isFinite, target.isFinite else { return nil }
        return min(target, potential)
    }

    /// Brightness set (PLAN 12.23, 12.27). `clearFrost` = Clear glass with blur, `plainClear` = Clear glass without blur, where the text sits
    /// straight on the desktop and needs more punch.
    enum Mode: Equatable {
        case standard, clearFrost, plainClear

        /// Filled part of the current line.
        var base: CGFloat {
            switch self {
            case .standard: return Metrics.fillMultiplier
            case .clearFrost: return 1.22
            case .plainClear: return 1.5
            }
        }
        /// Emphasis peak for the weakest group (s = 0).
        var peakMin: CGFloat {
            switch self {
            case .standard: return Metrics.peakMin
            case .clearFrost: return 1.38
            case .plainClear: return 1.65
            }
        }
        /// Emphasis peak for the strongest group (s = 1). This is also the `headroom` target the host
        /// asks for (`LyricHDR.headroom(target:)` and `LyricLineLayer.setDynamicRange(headroom:mode:)`).
        var peakMax: CGFloat {
            switch self {
            case .standard: return Metrics.peakMax
            case .clearFrost: return 1.85
            case .plainClear: return 2.2
            }
        }
    }

    /// Multiplier of the plain filled part under `headroom`.
    static func baseValue(headroom: CGFloat, mode: Mode = .standard) -> CGFloat { min(mode.base, headroom) }

    /// Emphasis peak for strength `s`: lerp(peakMin, peakMax, s) of the mode, capped by `headroom`.
    static func peakValue(strength s: CGFloat, headroom: CGFloat, mode: Mode = .standard) -> CGFloat {
        let k = s.isFinite ? min(max(s, 0), 1) : 0
        return min(mode.peakMin + (mode.peakMax - mode.peakMin) * k, headroom)
    }

    /// Multiplier at lift progress `k` (0 = base, 1 = peak), quantized to 0.01 so settled glyphs stop touching the color.
    static func level(progress k: CGFloat, strength s: CGFloat, headroom: CGFloat, mode: Mode = .standard) -> CGFloat {
        let base = baseValue(headroom: headroom, mode: mode)
        let peak = max(peakValue(strength: s, headroom: headroom, mode: mode), base)
        let kk = k.isFinite ? min(max(k, 0), 1) : 0
        return ((base + (peak - base) * kk) * 100).rounded() / 100
    }

    /// Gray extended-sRGB color `white` times SDR white; `headroom` is the largest value it will take.
    static func color(white: CGFloat, headroom: CGFloat, alpha: CGFloat = 1) -> CGColor? {
        guard white.isFinite, headroom.isFinite, let space = CGColorSpace(name: CGColorSpace.extendedSRGB) else { return nil }
        return CGColor(headroom: Float(max(headroom, white)), colorSpace: space,
                       red: white, green: white, blue: white, alpha: alpha)
    }
}
