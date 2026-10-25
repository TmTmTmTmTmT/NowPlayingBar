import CoreGraphics
import Testing
@testable import FloatingLyric

struct PlaylistNotesTests {
    @Test func topNoteOnlyWhenWindowSkipsTheStart() {
        #expect(PlaylistFormat.omittedBefore(first: 1) == nil)
        #expect(PlaylistFormat.omittedBefore(first: 2) == "앞 1곡 생략")
        #expect(PlaylistFormat.omittedBefore(first: 101) == "앞 100곡 생략")
    }

    @Test func noteRowsFollowTheWindow() {
        // Whole list: no notes.
        #expect(PlaylistRows.noteRows(firstIndex: 1, count: 50, total: 50) == (0, 0))
        // Starts at 1, cut at the end: footer only.
        #expect(PlaylistRows.noteRows(firstIndex: 1, count: 1000, total: 1200) == (0, 1))
        // Middle window: both.
        #expect(PlaylistRows.noteRows(firstIndex: 101, count: 1000, total: 2500) == (1, 1))
        // Window reaching the last track: top note only.
        #expect(PlaylistRows.noteRows(firstIndex: 201, count: 1000, total: 1200) == (1, 0))
    }

    @Test func shuffleAddsATopNoteAboveTheOmittedOne() {
        #expect(PlaylistRows.noteRows(firstIndex: 1, count: 50, total: 50, shuffle: true) == (1, 0))
        #expect(PlaylistRows.noteRows(firstIndex: 101, count: 1000, total: 2500, shuffle: true) == (2, 1))
        #expect(PlaylistFormat.shuffleNote == "Shuffle on · playlist order")
    }

    @Test func heightCountsTopNote() {
        let base = PlaylistView.preferredHeight(rows: 5)
        #expect(PlaylistView.preferredHeight(rows: 5, hasTopNote: true) - base == 28)
        #expect(PlaylistView.preferredHeight(rows: 5, hasFooter: true, hasTopNote: true)
                - PlaylistView.preferredHeight(rows: 5, hasFooter: true) == 28)
    }

    @Test func leadingNoteShiftsScrollMath() {
        // Rows 0 and 1 stay at the top so the note remains visible.
        #expect(PlaylistRows.scrollOffset(row: 1, rowHeight: 44, contentHeight: 2640, viewport: 440, leading: 28) == 0)
        // Row 12: one row above it stays visible, offset includes the note height.
        #expect(PlaylistRows.scrollOffset(row: 12, rowHeight: 44, contentHeight: 2640, viewport: 440, leading: 28) == CGFloat(512))
        #expect(PlaylistRows.isFullyVisible(row: 0, rowHeight: 44, offset: 0, viewport: 440, leading: 28))
        #expect(!PlaylistRows.isFullyVisible(row: 10, rowHeight: 44, offset: 0, viewport: 440, leading: 28))
    }
}
