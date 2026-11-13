import Foundation
import Testing
@testable import Lagoon

/// Which thumbnail a scrub position shows: the sheet it is on, and its cell.
@Suite("Trickplay source")
struct TrickplaySourceTests {
    /// Fifty thumbnails ten seconds apart, twenty to a sheet in a 5×4 grid.
    private func trickplay(
        sheets: Int = 3,
        columns: Int = 5,
        rows: Int = 4,
        interval: Double = 10,
        thumbnailCount: Int = 50
    ) -> TrickplaySource {
        TrickplaySource(
            sheetURLs: (0..<sheets).map { URL(string: "https://media.test/trickplay/\($0).jpg")! },
            tileSize: CGSize(width: 320, height: 180),
            columns: columns,
            rows: rows,
            interval: interval,
            thumbnailCount: thumbnailCount
        )
    }

    @Test func aPositionMapsToItsSheetColumnAndRow() {
        let source = trickplay()

        #expect(source.tile(at: 0) == TrickplayTile(sheet: 0, column: 0, row: 0))
        #expect(source.tile(at: 79) == TrickplayTile(sheet: 0, column: 2, row: 1))
        #expect(source.tile(at: 200) == TrickplayTile(sheet: 1, column: 0, row: 0))
        #expect(source.tile(at: 380) == TrickplayTile(sheet: 1, column: 3, row: 3))
    }

    @Test func aPositionPastEitherEndShowsTheNearestThumbnail() {
        let source = trickplay()

        #expect(source.tile(at: -30) == TrickplayTile(sheet: 0, column: 0, row: 0))
        #expect(source.tile(at: 9_000) == TrickplayTile(sheet: 2, column: 4, row: 1))
    }

    @Test func aThumbnailOnASheetTheServerDidNotListHasNoTile() {
        let source = trickplay(sheets: 2)

        #expect(source.tile(at: 390) == TrickplayTile(sheet: 1, column: 4, row: 3))
        #expect(source.tile(at: 400) == nil)
    }

    @Test func aSourceWithNothingToDivideByHasNoTiles() {
        #expect(trickplay(interval: 0).tile(at: 30) == nil)
        #expect(trickplay(columns: 0).tile(at: 30) == nil)
        #expect(trickplay(rows: 0).tile(at: 30) == nil)
        #expect(trickplay(thumbnailCount: 0).tile(at: 30) == nil)
    }
}
