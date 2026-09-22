import Foundation

/// Cached library identity and query scope, used by the Library's source
/// filter.
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
