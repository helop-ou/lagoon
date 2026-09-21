import Foundation

/// Cached library identity and query scope. These now populate
/// the unified Library's source filter rather than separate tabs.
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
