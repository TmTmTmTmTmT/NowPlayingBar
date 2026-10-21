import AppKit

/// The scrubber: a system `NSSlider` (standard macOS 26 look, accessibility and
/// keyboard support included). Drag to preview, release to commit the seek.
final class ScrubBar: NSSlider {
    var duration: Double = 1 {
        didSet { maxValue = max(duration, 1) }
    }
    var position: Double = 0 {
        didSet { if !isDragging { doubleValue = position } }
    }

    /// Called continuously while dragging (to update time labels).
    var onSeekPreview: ((Double) -> Void)?
    /// Called once on mouse-up (to commit the seek).
    var onSeekCommit: ((Double) -> Void)?

    private(set) var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        minValue = 0
        maxValue = max(duration, 1)
        isContinuous = true
        controlSize = .small
        target = self
        action = #selector(valueChanged)
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        super.mouseDown(with: event)    // modal tracking loop; returns on mouse-up
        isDragging = false
        onSeekCommit?(doubleValue)
    }

    @objc private func valueChanged() {
        onSeekPreview?(doubleValue)
        // Keyboard / accessibility adjustment: no drag, so commit right away.
        if !isDragging { onSeekCommit?(doubleValue) }
    }
}
