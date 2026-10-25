import XCTest
@testable import FloatingLyric

final class PlaylistViewTests: XCTestCase {
    func testDurationFormat() {
        XCTAssertEqual(PlaylistFormat.duration(193), "3:13")
        XCTAssertEqual(PlaylistFormat.duration(193.4), "3:13")
        XCTAssertEqual(PlaylistFormat.duration(193.6), "3:14")
        XCTAssertEqual(PlaylistFormat.duration(59.6), "1:00")
        XCTAssertEqual(PlaylistFormat.duration(5), "0:05")
        XCTAssertEqual(PlaylistFormat.duration(3665), "1:01:05")
        XCTAssertEqual(PlaylistFormat.duration(61 * 60 + 5), "1:01:05")
        XCTAssertEqual(PlaylistFormat.duration(3600), "1:00:00")
    }

    func testDurationUnknownIsEmpty() {
        XCTAssertEqual(PlaylistFormat.duration(0), "")
        XCTAssertEqual(PlaylistFormat.duration(0.4), "")
        XCTAssertEqual(PlaylistFormat.duration(-3), "")
        XCTAssertEqual(PlaylistFormat.duration(.nan), "")
    }

    func testFooter() {
        XCTAssertEqual(PlaylistFormat.footer(total: 2500, first: 101, count: 1000), "전체 2500곡 중 101–1100곡 표시")
        XCTAssertEqual(PlaylistFormat.footer(total: 1200, first: 1, count: 1000), "전체 1200곡 중 1–1000곡 표시")
    }

    func testRowState() {
        XCTAssertEqual(PlaylistRows.state(trackIndex: 3, current: 5), .past)
        XCTAssertEqual(PlaylistRows.state(trackIndex: 5, current: 5), .current)
        XCTAssertEqual(PlaylistRows.state(trackIndex: 6, current: 5), .upcoming)
        XCTAssertEqual(PlaylistRows.state(trackIndex: 1, current: nil), .upcoming)
    }

    func testRowForAbsoluteIndex() {
        XCTAssertEqual(PlaylistRows.row(forTrackIndex: 101, firstIndex: 101, count: 1000), 0)
        XCTAssertEqual(PlaylistRows.row(forTrackIndex: 1100, firstIndex: 101, count: 1000), 999)
        XCTAssertNil(PlaylistRows.row(forTrackIndex: 100, firstIndex: 101, count: 1000))
        XCTAssertNil(PlaylistRows.row(forTrackIndex: 1101, firstIndex: 101, count: 1000))
    }

    func testVisibility() {
        // Viewport 440pt = 10 rows at offset 88 (rows 2...11).
        XCTAssertTrue(PlaylistRows.isFullyVisible(row: 2, rowHeight: 44, offset: 88, viewport: 440))
        XCTAssertTrue(PlaylistRows.isFullyVisible(row: 11, rowHeight: 44, offset: 88, viewport: 440))
        XCTAssertFalse(PlaylistRows.isFullyVisible(row: 1, rowHeight: 44, offset: 88, viewport: 440))
        XCTAssertFalse(PlaylistRows.isFullyVisible(row: 12, rowHeight: 44, offset: 88, viewport: 440))
        XCTAssertFalse(PlaylistRows.isFullyVisible(row: 11, rowHeight: 44, offset: 60, viewport: 440))
    }

    func testScrollTargetIsSecondSlotAndClamped() {
        // Row 12 lands in the second slot: one row above it stays visible.
        XCTAssertEqual(PlaylistRows.scrollOffset(row: 12, rowHeight: 44, contentHeight: 2640, viewport: 440), 484)
        // First rows and tiny lists don't scroll.
        XCTAssertEqual(PlaylistRows.scrollOffset(row: 0, rowHeight: 44, contentHeight: 2640, viewport: 440), 0)
        XCTAssertEqual(PlaylistRows.scrollOffset(row: 1, rowHeight: 44, contentHeight: 2640, viewport: 440), 0)
        XCTAssertEqual(PlaylistRows.scrollOffset(row: 3, rowHeight: 44, contentHeight: 300, viewport: 440), 0)
        // Near the end the list can't scroll past its content.
        XCTAssertEqual(PlaylistRows.scrollOffset(row: 59, rowHeight: 44, contentHeight: 2640, viewport: 440), 2200)
    }

    func testPreferredHeight() {
        let base = PlaylistView.preferredHeight(rows: 5)
        XCTAssertEqual(PlaylistView.preferredHeight(rows: 6) - base, 44)
        XCTAssertGreaterThan(PlaylistView.preferredHeight(rows: 5, hasFooter: true), base)
    }

    func testHoveredTrackFromPointer() {
        func hit(_ y: CGFloat, inside: Bool = true, pressed: Bool = false, leading: CGFloat = 0, count: Int = 3) -> Int? {
            PlaylistRows.hoveredTrack(y: y, pointerInside: inside, pressed: pressed, leading: leading,
                                      rowHeight: 44, count: count)
        }
        XCTAssertEqual(hit(0), 0)
        XCTAssertEqual(hit(43.9), 0)
        XCTAssertEqual(hit(44), 1)
        XCTAssertEqual(hit(131), 2)
        XCTAssertNil(hit(132))                       // past the last track
        XCTAssertNil(hit(-1))
        XCTAssertNil(hit(20, inside: false))         // pointer outside list/window
        XCTAssertNil(hit(20, pressed: true))         // dragging
        XCTAssertNil(hit(10, leading: 28))           // over the top note
        XCTAssertEqual(hit(28 + 44, leading: 28), 1)
    }
}
