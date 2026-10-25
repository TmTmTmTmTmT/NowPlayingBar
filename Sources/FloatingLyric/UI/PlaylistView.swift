import AppKit
import QuartzCore

/// Pure text formatting for the playlist; kept free of AppKit state for tests.
enum PlaylistFormat {
    /// "m:ss", "h:mm:ss" from one hour up; unknown (0, negative, NaN) is empty.
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        guard total > 0 else { return "" }
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Footer of a truncated list; `first` is the absolute index of the first shown row.
    static func footer(total: Int, first: Int, count: Int) -> String {
        "전체 \(total)곡 중 \(first)–\(first + count - 1)곡 표시"
    }

    /// Top one-liner when the window starts after track 1 (PLAN 3.5 v3); nil otherwise.
    static func omittedBefore(first: Int) -> String? {
        first > 1 ? "앞 \(first - 1)곡 생략" : nil
    }

    /// Top note while shuffle is on: the list is in playlist order, not play order (FIX_GUIDE F11).
    static let shuffleNote = "Shuffle on · playlist order"
}

enum PlaylistRowState: Equatable {
    case past, current, upcoming
}

/// Row classification and scroll arithmetic, separate from the view so it can be tested.
enum PlaylistRows {
    /// Rows before the current track fade; with no current track every row is upcoming.
    static func state(trackIndex: Int, current: Int?) -> PlaylistRowState {
        guard let current else { return .upcoming }
        if trackIndex == current { return .current }
        return trackIndex < current ? .past : .upcoming
    }

    /// Table row of an absolute track index, nil when it lies outside the shown window.
    /// Counts tracks only; the optional top note line is not a track row.
    static func row(forTrackIndex index: Int, firstIndex: Int, count: Int) -> Int? {
        let row = index - firstIndex
        return (0..<count).contains(row) ? row : nil
    }

    /// Note lines around the tracks: the shuffle note first on top while shuffle is on, then
    /// one when the window skips the start, and one at the end only when it stops before the last track.
    static func noteRows(firstIndex: Int, count: Int, total: Int, shuffle: Bool = false) -> (top: Int, end: Int) {
        ((shuffle ? 1 : 0) + (firstIndex > 1 ? 1 : 0), firstIndex + count - 1 < total ? 1 : 0)
    }

    /// Position (0-based within the shown tracks) of the track under the pointer, nil when the pointer is
    /// outside the list, a button is held (drag), or it is over a note line / past the last track.
    /// `y` is measured from the top of the table content; `leading` is the height of the top notes.
    static func hoveredTrack(y: CGFloat, pointerInside: Bool, pressed: Bool, leading: CGFloat,
                             rowHeight: CGFloat, count: Int) -> Int? {
        guard pointerInside, !pressed, rowHeight > 0, y >= leading else { return nil }
        let pos = Int(((y - leading) / rowHeight).rounded(.down))
        return (0..<count).contains(pos) ? pos : nil
    }

    /// True when the whole row lies inside the viewport.
    /// `leading` is the height of a note line above the first track row.
    static func isFullyVisible(row: Int, rowHeight: CGFloat, offset: CGFloat, viewport: CGFloat,
                               leading: CGFloat = 0) -> Bool {
        let top = leading + CGFloat(row) * rowHeight
        return top >= offset && top + rowHeight <= offset + viewport
    }

    /// Scroll offset that puts `row` in the second slot (one row above it stays visible),
    /// clamped to the scrollable range.
    /// Rows 0 and 1 stay at the top so a leading note remains visible.
    static func scrollOffset(row: Int, rowHeight: CGFloat, contentHeight: CGFloat, viewport: CGFloat,
                             leading: CGFloat = 0) -> CGFloat {
        let wanted = row <= 1 ? 0 : leading + CGFloat(row - 1) * rowHeight
        return min(max(wanted, 0), max(contentHeight - viewport, 0))
    }
}

/// The playlist tab: header, recycled 44pt rows (NSTableView), truncation footer and
/// the empty/error states. Row artwork is loaded lazily through `artworkLoader`.
final class PlaylistView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Metrics {
        static let headerHeight: CGFloat = 40
        static let rowHeight: CGFloat = 44
        static let footerHeight: CGFloat = 28
        static let bottomPadding: CGFloat = 8
        static let sidePadding: CGFloat = 16
        static let maxPendingArtwork = 2
        static let artworkCacheLimit = 300
        static let currentSlotRows = 1            // current row sits in the second slot
        static let maxAnimatedRows: CGFloat = 4   // farther jumps snap: rows in between aren't built
        static let springResponse: CGFloat = 0.5
        static let springDamping: CGFloat = 1.0
        static let messageSpacing: CGFloat = 4
    }

    /// Called with the absolute AppleScript track index of the clicked row.
    var onSelect: ((Int) -> Void)?
    /// Asks the host for a row's artwork; the completion may be called from any thread.
    var artworkLoader: ((Int, @escaping (NSImage?) -> Void) -> Void)?

    static func preferredHeight(rows: Int, hasFooter: Bool = false, hasTopNote: Bool = false) -> CGFloat {
        Metrics.headerHeight + CGFloat(max(rows, 0)) * Metrics.rowHeight
            + (hasFooter ? Metrics.footerHeight : 0) + (hasTopNote ? Metrics.footerHeight : 0)
            + Metrics.bottomPadding
    }

    private let headerView = NSView()
    private let nameField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let messageView = NSView()
    private let messageTitle = NSTextField(wrappingLabelWithString: "")
    private let messageDetail = NSTextField(wrappingLabelWithString: "")

    private var palette = PlaylistPalette()
    private var snapshot: PlaylistSnapshot?
    private var currentIndex: Int?
    private var isPlaying = false
    private var needsInitialScroll = false
    private var boundsObserver: NSObjectProtocol?
    private var hoveredPosition: Int?
    private var hoverTracking: NSTrackingArea?

    private enum ArtworkState {
        case pending
        case done(NSImage)
        case failed
    }
    private var artworkStates: [Int: ArtworkState] = [:]
    private var pendingArtwork = 0
    /// Bumped when the playlist changes so late completions of the old one are dropped.
    private var artworkGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setUpHeader()
        setUpTable()
        setUpMessage()
        apply(glass: .regular)
        showLoading()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    // MARK: Hover (single tracking area)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect,
                                            .enabledDuringMouseDrag],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) { updateHover() }
    override func mouseEntered(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) { updateHover() }
    override func mouseDragged(with event: NSEvent) { updateHover(pressed: true) }
    override func mouseUp(with event: NSEvent) { updateHover(pressed: false) }

    /// Recomputes the one hovered row from the pointer; `pressed` overrides the live button state.
    private func updateHover(pressed: Bool? = nil) {
        var position: Int?
        if let snap = snapshot, let window, !scrollView.isHidden {
            let windowPoint = window.mouseLocationOutsideOfEventStream
            let inScroll = scrollView.convert(windowPoint, from: nil)
            let inside = scrollView.bounds.contains(inScroll) && bounds.contains(convert(windowPoint, from: nil))
            let down = pressed ?? (NSEvent.pressedMouseButtons & 1 != 0)
            position = PlaylistRows.hoveredTrack(
                y: tableView.convert(windowPoint, from: nil).y, pointerInside: inside, pressed: down,
                leading: CGFloat(notes(snap).top) * Metrics.footerHeight, rowHeight: Metrics.rowHeight,
                count: snap.tracks.count)
        }
        hoveredPosition = position
        applyHover()
    }

    private func applyHover() {
        guard let snap = snapshot else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            guard let pos = trackPosition(ofRow: row, in: snap),
                  let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? PlaylistRowView
            else { continue }
            view.setHighlighted(pos == hoveredPosition)
        }
    }

    // MARK: Setup

    private func setUpHeader() {
        nameField.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.lineBreakMode = .byTruncatingTail
        countField.font = .systemFont(ofSize: 13)
        countField.alignment = .right
        headerView.addSubview(nameField)
        headerView.addSubview(countField)
        addSubview(headerView)
    }

    private func setUpTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("track"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.rowHeight = Metrics.rowHeight
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pumpArtwork(); self?.updateHover() }
        }
        addSubview(scrollView)
    }

    private func setUpMessage() {
        messageTitle.font = .systemFont(ofSize: 13)
        messageDetail.font = .systemFont(ofSize: 11)
        [messageTitle, messageDetail].forEach {
            $0.alignment = .center
            $0.isSelectable = false
            messageView.addSubview($0)
        }
        addSubview(messageView)
    }

    // MARK: Public

    func show(result: PlaylistResult) {
        switch result {
        case .snapshot(let snap): showSnapshot(snap)
        case .noPlaylist: showMessage("재생 중인 재생목록이 없습니다")
        case .denied: showMessage("Music 제어 권한이 필요합니다", detail: "시스템 설정 ▸ 개인정보 보호 및 보안 ▸ 자동화")
        case .failed: showMessage("재생목록을 가져오지 못했습니다")
        }
    }

    func showLoading() {
        showMessage("재생목록을 불러오는 중…")
    }

    /// Moves the highlight and animation without rebuilding rows, and scrolls the current
    /// row into view when it is out of sight.
    func updateCurrent(index: Int?, isPlaying: Bool) {
        let indexChanged = index != currentIndex
        currentIndex = index
        self.isPlaying = isPlaying
        guard snapshot != nil else { return }
        refreshVisibleRows()
        if indexChanged { scrollToCurrent(onlyIfHidden: true, animated: true) }
    }

    func apply(glass: GlassAppearance) {
        palette = PlaylistPalette(solid: glass.solidElements)
        nameField.textColor = palette.primary
        countField.textColor = palette.secondary
        messageTitle.textColor = palette.secondary
        messageDetail.textColor = palette.secondary
        if snapshot != nil {
            tableView.reloadData()
            tableView.layoutSubtreeIfNeeded()
        }
    }

    // MARK: Content switching

    private func showSnapshot(_ snap: PlaylistSnapshot) {
        let previous = snapshot
        let sameList = previous?.name == snap.name
        if !sameList { resetArtwork() }
        snapshot = snap
        currentIndex = snap.currentIndex
        nameField.stringValue = snap.name
        countField.stringValue = "\(snap.totalCount)곡"
        messageView.isHidden = true
        headerView.isHidden = false
        scrollView.isHidden = false
        tableView.reloadData()
        needsLayout = true
        layoutSubtreeIfNeeded()
        // Always place the list on first show / a different playlist; a refresh keeps the user's scroll.
        if sameList {
            scrollToCurrent(onlyIfHidden: true, animated: false)
        } else {
            needsInitialScroll = true
            applyInitialScrollIfPossible()
        }
        pumpArtwork()
    }

    private func showMessage(_ title: String, detail: String? = nil) {
        if snapshot != nil { resetArtwork() }
        snapshot = nil
        needsInitialScroll = false
        tableView.reloadData()
        headerView.isHidden = true
        scrollView.isHidden = true
        messageView.isHidden = false
        messageTitle.stringValue = title
        messageDetail.stringValue = detail ?? ""
        messageDetail.isHidden = detail == nil
        needsLayout = true
    }

    private func resetArtwork() {
        artworkStates.removeAll()
        artworkGeneration += 1
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        headerView.frame = NSRect(x: 0, y: h - Metrics.headerHeight, width: w, height: Metrics.headerHeight)
        let countWidth: CGFloat = 72
        countField.frame = NSRect(x: w - Metrics.sidePadding - countWidth, y: (Metrics.headerHeight - 16) / 2,
                                  width: countWidth, height: 16)
        nameField.frame = NSRect(x: Metrics.sidePadding, y: (Metrics.headerHeight - 16) / 2,
                                 width: max(0, w - 2 * Metrics.sidePadding - countWidth - 8), height: 16)
        scrollView.frame = NSRect(x: 0, y: Metrics.bottomPadding, width: w,
                                  height: max(0, h - Metrics.headerHeight - Metrics.bottomPadding))
        tableView.tableColumns.first?.width = scrollView.contentSize.width
        messageView.frame = bounds
        let textWidth = max(0, w - 2 * Metrics.sidePadding)
        let titleH = ceil(messageTitle.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        let detailH = messageDetail.isHidden ? 0
            : ceil(messageDetail.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        let gap = messageDetail.isHidden ? 0 : Metrics.messageSpacing
        var y = (h + titleH + gap + detailH) / 2 - titleH
        messageTitle.frame = NSRect(x: Metrics.sidePadding, y: y, width: textWidth, height: titleH)
        y -= gap + detailH
        messageDetail.frame = NSRect(x: Metrics.sidePadding, y: y, width: textWidth, height: detailH)
        applyInitialScrollIfPossible()
        pumpArtwork()
    }

    private func applyInitialScrollIfPossible() {
        guard needsInitialScroll, scrollView.contentSize.height > 0 else { return }
        needsInitialScroll = false
        tableView.layoutSubtreeIfNeeded()
        scrollToCurrent(onlyIfHidden: false, animated: false)
    }

    // MARK: Scrolling

    private func scrollToCurrent(onlyIfHidden: Bool, animated: Bool) {
        guard let snap = snapshot, let current = currentIndex,
              let row = PlaylistRows.row(forTrackIndex: current, firstIndex: snap.firstIndex,
                                         count: snap.tracks.count) else { return }
        let leading = CGFloat(notes(snap).top) * Metrics.footerHeight
        let clip = scrollView.contentView
        let viewport = clip.bounds.height
        let from = clip.bounds.origin.y
        if onlyIfHidden, PlaylistRows.isFullyVisible(row: row, rowHeight: Metrics.rowHeight,
                                                     offset: from, viewport: viewport, leading: leading) { return }
        let target = PlaylistRows.scrollOffset(row: row, rowHeight: Metrics.rowHeight,
                                               contentHeight: tableView.frame.height, viewport: viewport,
                                               leading: leading)
        guard target != from else { return }
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && abs(target - from) <= Metrics.maxAnimatedRows * Metrics.rowHeight
        clip.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(clip)
        guard animate, let layer = clip.layer else { return }
        let spring = CASpringAnimation(keyPath: "bounds.origin.y")
        let stiffness = pow(2 * .pi / Metrics.springResponse, 2)
        spring.mass = 1
        spring.stiffness = stiffness
        spring.damping = 2 * sqrt(stiffness) * Metrics.springDamping
        spring.fromValue = from
        spring.toValue = target
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "playlistScroll")
    }

    // MARK: Table

    private func notes(_ snap: PlaylistSnapshot) -> (top: Int, end: Int) {
        PlaylistRows.noteRows(firstIndex: snap.firstIndex, count: snap.tracks.count, total: snap.totalCount,
                              shuffle: snap.shuffleEnabled)
    }

    /// Index into `snap.tracks` for a table row, nil for the note lines.
    private func trackPosition(ofRow row: Int, in snap: PlaylistSnapshot) -> Int? {
        let pos = row - notes(snap).top
        return (0..<snap.tracks.count).contains(pos) ? pos : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let snap = snapshot else { return 0 }
        let n = notes(snap)
        return n.top + snap.tracks.count + n.end
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let snap = snapshot, trackPosition(ofRow: row, in: snap) == nil else { return Metrics.rowHeight }
        return Metrics.footerHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let snap = snapshot else { return nil }
        guard let pos = trackPosition(ofRow: row, in: snap) else {
            let text: String
            if row >= notes(snap).top {
                text = PlaylistFormat.footer(total: snap.totalCount, first: snap.firstIndex, count: snap.tracks.count)
            } else if snap.shuffleEnabled, row == 0 {
                text = PlaylistFormat.shuffleNote
            } else {
                text = PlaylistFormat.omittedBefore(first: snap.firstIndex) ?? ""
            }
            let footer = tableView.makeView(withIdentifier: PlaylistFooterView.identifier, owner: nil)
                as? PlaylistFooterView ?? PlaylistFooterView()
            footer.configure(text: text, palette: palette)
            return footer
        }
        let view = tableView.makeView(withIdentifier: PlaylistRowView.identifier, owner: nil)
            as? PlaylistRowView ?? PlaylistRowView()
        configure(view, position: pos, in: snap)
        return view
    }

    private func configure(_ view: PlaylistRowView, position: Int, in snap: PlaylistSnapshot) {
        let track = snap.tracks[position]
        view.configure(track: track,
                       state: PlaylistRows.state(trackIndex: track.index, current: currentIndex),
                       isPlaying: isPlaying, artwork: artwork(for: track.index), palette: palette)
        view.onClick = { [weak self] in self?.onSelect?(track.index) }
        view.onPointerEvent = { [weak self] pressed in self?.updateHover(pressed: pressed) }
        view.setHighlighted(position == hoveredPosition)
    }

    private func refreshVisibleRows() {
        guard let snap = snapshot else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            if let pos = trackPosition(ofRow: row, in: snap),
               let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? PlaylistRowView {
                configure(view, position: pos, in: snap)
            }
        }
    }

    // MARK: Artwork

    private func artwork(for trackIndex: Int) -> PlaylistArtwork {
        switch artworkStates[trackIndex] {
        case .done(let image): return .image(image)
        case .failed: return .missing
        case .pending, nil: return .loading
        }
    }

    /// Requests artwork for visible, not yet requested rows, two at a time.
    private func pumpArtwork() {
        guard let snap = snapshot, let loader = artworkLoader,
              pendingArtwork < Metrics.maxPendingArtwork else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        if artworkStates.count > Metrics.artworkCacheLimit { trimArtworkCache(keeping: visible, in: snap) }
        for row in visible.location..<(visible.location + visible.length) {
            guard pendingArtwork < Metrics.maxPendingArtwork else { break }
            guard let pos = trackPosition(ofRow: row, in: snap) else { continue }
            let index = snap.tracks[pos].index
            guard artworkStates[index] == nil else { continue }
            artworkStates[index] = .pending
            pendingArtwork += 1
            let generation = artworkGeneration
            loader(index) { [weak self] image in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.finishArtwork(index: index, image: image, generation: generation) }
                } else {
                    DispatchQueue.main.async { self?.finishArtwork(index: index, image: image, generation: generation) }
                }
            }
        }
    }

    private func finishArtwork(index: Int, image: NSImage?, generation: Int) {
        pendingArtwork = max(0, pendingArtwork - 1)
        if generation == artworkGeneration, let snap = snapshot {
            artworkStates[index] = image.map(ArtworkState.done) ?? .failed
            if let pos = PlaylistRows.row(forTrackIndex: index, firstIndex: snap.firstIndex, count: snap.tracks.count),
               let view = tableView.view(atColumn: 0, row: pos + notes(snap).top, makeIfNecessary: false) as? PlaylistRowView {
                view.setArtwork(artwork(for: index))
            }
        }
        pumpArtwork()
    }

    /// Drops loaded images of rows far from the viewport; failures stay so they aren't re-requested.
    private func trimArtworkCache(keeping visible: NSRange, in snap: PlaylistSnapshot) {
        let keep = Set((visible.location..<(visible.location + visible.length)).compactMap {
            trackPosition(ofRow: $0, in: snap).map { snap.tracks[$0 - notes(snap).top].index }
        })
        for (index, state) in artworkStates where !keep.contains(index) {
            if case .done = state { artworkStates[index] = nil }
        }
    }
}
