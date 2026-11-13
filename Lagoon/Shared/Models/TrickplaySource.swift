import Foundation
import LagoonEngine

/// Trickplay preview sheets: resolved URLs plus each sheet's grid.
/// `tile(at:)` maps a position to a tile.
nonisolated struct TrickplaySource: Equatable {
    let sheetURLs: [URL]
    /// One thumbnail's pixel size as the server declared it.
    let tileSize: CGSize
    let columns: Int
    let rows: Int
    /// Seconds between thumbnails (the wire value is milliseconds).
    let interval: Double
    let thumbnailCount: Int
    /// Header credential `TrickplayLoader` applies per fetch. The URLs carry
    /// no token and the route refuses requests without one.
    var authorization: MediaRequestAuthorization? = nil

    var tilesPerSheet: Int { columns * rows }

    /// Which sheet and cell a position lands in, or nil if it falls outside
    /// what the server generated.
    func tile(at seconds: Double) -> TrickplayTile? {
        guard interval > 0, tilesPerSheet > 0, thumbnailCount > 0 else { return nil }
        let index = min(max(Int(seconds / interval), 0), thumbnailCount - 1)
        let sheet = index / tilesPerSheet
        guard sheetURLs.indices.contains(sheet) else { return nil }
        let cell = index % tilesPerSheet
        return TrickplayTile(sheet: sheet, column: cell % columns, row: cell / columns)
    }
}

nonisolated struct TrickplayTile: Equatable {
    let sheet: Int
    let column: Int
    let row: Int
}
