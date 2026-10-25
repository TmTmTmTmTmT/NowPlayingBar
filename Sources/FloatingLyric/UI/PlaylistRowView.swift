import AppKit

/// Text colors shared by all playlist cells; `solid` mirrors the host's `solidElements`.
struct PlaylistPalette: Equatable {
    var solid = false

    /// Same rule as the host card's solid text: white on dark, black on light.
    static func solidColor(alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return (dark ? NSColor.white : NSColor.black).withAlphaComponent(alpha)
        }
    }
    var primary: NSColor { solid ? Self.solidColor(alpha: 1) : .labelColor }
    var secondary: NSColor { solid ? Self.solidColor(alpha: 0.8) : .secondaryLabelColor }
    /// Fill base for the current/hover backgrounds and artwork placeholders.
    var tint: NSColor { solid ? Self.solidColor(alpha: 1) : .labelColor }
}

/// What a row shows besides its track: artwork state is resolved by the view.
enum PlaylistArtwork {
    case loading
    case image(NSImage)
    case missing
}

/// One recycled 44pt track row. Layout is manual: no Auto Layout cost for 1000-row lists.
final class PlaylistRowView: NSView {
    private enum Metrics {
        static let inset: CGFloat = 4          // row fill inset from the list edge
        static let fillRadius: CGFloat = 8
        static let artworkSize: CGFloat = 32
        static let artworkRadius: CGFloat = 6
        static let artworkX: CGFloat = 12
        static let textGap: CGFloat = 10
        static let iconWidth: CGFloat = 16
        static let durationWidth: CGFloat = 52
        static let trailing: CGFloat = 12
        static let currentFill: CGFloat = 0.08
        static let hoverFill: CGFloat = 0.05
        static let placeholderFill: CGFloat = 0.10
        static let pastAlpha: CGFloat = 0.5
    }

    static let identifier = NSUserInterfaceItemIdentifier("PlaylistRow")

    var onClick: (() -> Void)?
    /// Called on mouse down/up (`pressed` = button state after the event) so the list can recompute the hover.
    var onPointerEvent: ((Bool) -> Void)?

    private let fillView = NSView()
    private let artworkView = NSImageView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let artistField = NSTextField(labelWithString: "")
    private let durationField = NSTextField(labelWithString: "")

    private var palette = PlaylistPalette()
    private var state = PlaylistRowState.upcoming
    private var isPlaying = false
    private var artwork = PlaylistArtwork.loading
    private var hovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        wantsLayer = true
        fillView.wantsLayer = true
        fillView.layer?.cornerRadius = Metrics.fillRadius
        fillView.layer?.cornerCurve = .continuous
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = Metrics.artworkRadius
        artworkView.layer?.cornerCurve = .continuous
        artworkView.layer?.masksToBounds = true
        iconView.imageScaling = .scaleProportionallyDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)

        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        artistField.font = .systemFont(ofSize: 11)
        durationField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        durationField.alignment = .right
        [titleField, artistField, durationField].forEach { $0.lineBreakMode = .byTruncatingTail }
        [fillView, artworkView, iconView, titleField, artistField, durationField].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Sets everything a recycled row needs; cheap enough to call for every visible row on a state change.
    func configure(track: PlaylistTrack, state: PlaylistRowState, isPlaying: Bool,
                   artwork: PlaylistArtwork, palette: PlaylistPalette) {
        if titleField.stringValue != track.title { titleField.stringValue = track.title }
        if artistField.stringValue != track.artist { artistField.stringValue = track.artist }
        let duration = PlaylistFormat.duration(track.duration)
        if durationField.stringValue != duration { durationField.stringValue = duration }
        self.palette = palette
        self.state = state
        self.isPlaying = isPlaying
        self.artwork = artwork
        applyState()
        needsLayout = true
    }

    func setArtwork(_ artwork: PlaylistArtwork) {
        self.artwork = artwork
        applyArtwork()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
        iconView.removeAllSymbolEffects(animated: false)
    }

    // MARK: State

    private func applyState() {
        let current = state == .current
        titleField.textColor = palette.primary
        artistField.textColor = palette.secondary
        durationField.textColor = palette.secondary
        iconView.contentTintColor = palette.primary
        iconView.isHidden = !current
        let alpha: CGFloat = state == .past ? Metrics.pastAlpha : 1
        [artworkView, titleField, artistField, durationField].forEach { $0.alphaValue = alpha }
        applyFill()
        applyArtwork()
        applyIconEffect()
    }

    private func applyFill() {
        let amount: CGFloat = state == .current ? Metrics.currentFill : (hovered ? Metrics.hoverFill : 0)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fillView.layer?.backgroundColor = amount > 0
                ? palette.tint.withAlphaComponent(amount).cgColor : nil
        }
    }

    private func applyArtwork() {
        switch artwork {
        case .image(let image):
            artworkView.image = image
            artworkView.imageScaling = .scaleAxesIndependently
            artworkView.contentTintColor = nil
            setPlaceholderFill(false)
        case .loading:
            artworkView.image = nil
            setPlaceholderFill(true)
        case .missing:
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            artworkView.imageScaling = .scaleNone
            artworkView.contentTintColor = palette.secondary
            setPlaceholderFill(true)
        }
    }

    private func setPlaceholderFill(_ on: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            artworkView.layer?.backgroundColor = on
                ? palette.tint.withAlphaComponent(Metrics.placeholderFill).cgColor : nil
        }
    }

    /// Variable color runs only for the playing current row; Reduce Motion keeps it still.
    private func applyIconEffect() {
        iconView.removeAllSymbolEffects(animated: false)
        guard state == .current, isPlaying,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        iconView.addSymbolEffect(.variableColor.iterative.dimInactiveLayers.reversing, options: .repeating)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
        applyArtwork()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        fillView.frame = NSRect(x: Metrics.inset, y: 2, width: w - 2 * Metrics.inset, height: h - 4)
        artworkView.frame = NSRect(x: Metrics.artworkX, y: (h - Metrics.artworkSize) / 2,
                                   width: Metrics.artworkSize, height: Metrics.artworkSize)
        let textX = Metrics.artworkX + Metrics.artworkSize + Metrics.textGap
        let durationX = w - Metrics.trailing - Metrics.durationWidth
        durationField.frame = NSRect(x: durationX, y: (h - 14) / 2, width: Metrics.durationWidth, height: 14)
        let iconShift = state == .current ? Metrics.iconWidth : 0
        iconView.frame = NSRect(x: textX, y: h / 2 + 1, width: Metrics.iconWidth - 2, height: 16)
        let textWidth = max(0, durationX - 8 - textX)
        titleField.frame = NSRect(x: textX + iconShift, y: h / 2 + 1,
                                  width: max(0, textWidth - iconShift), height: 16)
        artistField.frame = NSRect(x: textX, y: h / 2 - 15, width: textWidth, height: 14)
    }

    // MARK: Mouse

    /// Hover highlight is driven by the list view (one tracking area, FIX_GUIDE F20).
    func setHighlighted(_ on: Bool) {
        guard on != hovered else { return }
        hovered = on
        applyFill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPointerEvent?(true) }

    override func mouseUp(with event: NSEvent) {
        onPointerEvent?(false)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// The one-line notes of a windowed list: "앞 N곡 생략" on top, "전체 N곡 중 a–b곡 표시" at the end.
final class PlaylistFooterView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("PlaylistFooter")
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(text: String, palette: PlaylistPalette) {
        label.stringValue = text
        label.textColor = palette.secondary
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 12, y: (bounds.height - 14) / 2, width: max(0, bounds.width - 24), height: 14)
    }
}
