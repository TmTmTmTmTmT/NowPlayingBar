import AppKit

/// The Dolby double-D mark: the user's reference image with the background removed
/// (31×22 px alpha mask), tinted with `color`.
final class AtmosBadgeView: NSView {
    static let size = NSSize(width: 17, height: 12)      // 31:22 like the mask
    var color: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { Self.size }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let mask: NSImage? = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAB8AAAAWCAYAAAA4oUfxAAAAAXNSR0IArs4c6QAAADhlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAAH6ADAAQAAAABAAAAFgAAAABeX5W9AAABbElEQVRIDaWWTU7EMAyFWzowA+IqnIMta/acgh1ii9gze7ZzD27AkiuABMxPp3xGSRU8beMYS0+JnfS9OHGbVl3X7RO09NfgBVyCuvqnwXEBVuADbIFo/KKik7Mbjz6kVzniWiYYyHfMWdR13ebmQie79Q7Oc3Ot4pFnzgI20dEtwg2xLTAd15EmyPifmfFvq7DwlIo3ZLcaWgDxJ+KzobGxWOm2R55Zev5hu6Uuiqw080j+EDuhvVO+yfVmviHzeVQgc6mF0+hbW694hXhf0YhbXteDNXm3XT5OvfgBqzHgFidxV7bputziKYm37xX/UoLaV8PDrlf8UdHdK9/kequ94cz3USEUX+/HeK71ZP6cCotAKL5lTkyPl2beIjT6/WYH1gicaJExvzTzxRhRiMu4+RW0isulIZfJ5OURtl/udFP1W8SXkB6D7F+MZC8LAGd0b8WfNM5Jm/xQvoHryQeNg/DIv9wr2IE/9gMPOxEIB6U9SQAAAABJRU5ErkJggg==").flatMap { NSImage(data: $0) }

    override func draw(_ dirtyRect: NSRect) {
        guard let mask = Self.mask else { return }
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        let tint = NSColor(cgColor: resolved) ?? color
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let cg = mask.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.clip(to: bounds, mask: cg)       // the mask's alpha shapes the fill
        ctx.setFillColor(tint.cgColor)
        ctx.fill(bounds)
        ctx.restoreGState()
    }
}
