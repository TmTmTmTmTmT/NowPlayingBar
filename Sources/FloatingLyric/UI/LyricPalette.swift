import AppKit

/// Text colors for lyrics. Dynamic `NSColor`s, resolved per appearance at render
/// time because the bitmaps bake the color in (GUIDELINES 4).
struct LyricPalette: Equatable {
    var active: NSColor
    /// Not yet sung part of the active line.
    var unfilled: NSColor
    var secondary: NSColor

    enum Metrics {
        static let unfilledAlpha: CGFloat = 0.35
        static let clearUnfilledAlpha: CGFloat = 0.5
    }

    init(glass: GlassAppearance) {
        if glass.solidElements {
            active = Self.solidColor(alpha: 1)
            secondary = Self.solidColor(alpha: 0.8)
        } else {
            active = .labelColor
            secondary = .secondaryLabelColor
        }
        unfilled = Self.dimmed(active, alpha: glass.isClear ? Metrics.clearUnfilledAlpha : Metrics.unfilledAlpha)
    }

    /// `color` with its alpha replaced, but resolved only when drawn: the render-time appearance picks
    /// the base color first (a pinned Light panel under a Dark system must give the Light one).
    static func dimmed(_ color: NSColor, alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var out = NSColor.clear
            appearance.performAsCurrentDrawingAppearance {
                out = NSColor(cgColor: color.cgColor)?.withAlphaComponent(alpha) ?? .clear
            }
            return out
        }
    }

    /// Same rule as the host card's fixed-color text: white on dark, black on light.
    static func solidColor(alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return (dark ? NSColor.white : NSColor.black).withAlphaComponent(alpha)
        }
    }

    /// CGColor of `color` as it looks under `appearance`.
    static func resolve(_ color: NSColor, in appearance: NSAppearance) -> CGColor {
        var out = color.cgColor
        appearance.performAsCurrentDrawingAppearance { out = color.cgColor }
        return out
    }
}
