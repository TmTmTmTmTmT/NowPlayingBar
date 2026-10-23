import AppKit

/// Menu row that applies its choice without dismissing the menu (a regular
/// NSMenuItem closes the menu on click; view-based items do not).
final class MenuChoiceView: NSView {
    private let title: String
    private var hovering = false
    var checked = false { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?

    init(title: String, width: CGFloat = 260) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { onSelect?() }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let color: NSColor = hovering ? .white : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: color]
        let h = NSFont.menuFont(ofSize: 13).boundingRectForFont.height
        let y = (bounds.height - h) / 2 - NSFont.menuFont(ofSize: 13).descender * 0 + 1
        if checked { ("✓" as NSString).draw(at: NSPoint(x: 14, y: y), withAttributes: attrs) }
        (title as NSString).draw(at: NSPoint(x: 32, y: y), withAttributes: attrs)
    }
}

extension NSMenu {
    /// Single-choice menu whose rows keep the menu open when picked.
    static func keepOpenChoices(_ choices: [(String, Int)], current: Int,
                                onSelect: @escaping (Int) -> Void) -> NSMenu {
        let menu = NSMenu()
        var views: [MenuChoiceView] = []
        for (title, value) in choices {
            let v = MenuChoiceView(title: title)
            v.checked = value == current
            views.append(v)
            v.onSelect = { [unowned v] in
                views.forEach { $0.checked = ($0 === v) }
                onSelect(value)
            }
            let item = NSMenuItem()
            item.view = v
            menu.addItem(item)
        }
        return menu
    }
}

/// Menu row with a title, a slider and a live percent readout; the menu stays open while dragging.
final class MenuSliderView: NSView {
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider: NSSlider
    private let onChange: (Int) -> Void

    init(title: String, value: Int, range: ClosedRange<Int>, onChange: @escaping (Int) -> Void) {
        slider = NSSlider(value: Double(value), minValue: Double(range.lowerBound),
                          maxValue: Double(range.upperBound), target: nil, action: nil)
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 44))
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 13)
        label.frame = NSRect(x: 14, y: 24, width: 150, height: 17)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 170, y: 24, width: 46, height: 17)
        valueLabel.stringValue = "\(value)%"
        slider.frame = NSRect(x: 14, y: 4, width: 202, height: 18)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        [label, valueLabel, slider].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        let v = Int(slider.doubleValue.rounded())
        valueLabel.stringValue = "\(v)%"
        onChange(v)
    }
}
