import Foundation

/// The little a library tab actually needs: enough to draw itself and to
/// scope a query (HEL-61).
///
/// Exists so the tab bar can be cached. `MediaItem` is `Decodable` only —
/// deliberately, it is a wire type — and `LibraryView` never wanted more
/// than these three fields anyway.
nonisolated struct LibraryTab: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let collectionType: String?

    init(_ item: MediaItem) {
        id = item.id
        name = item.name
        collectionType = item.collectionType
    }
}
