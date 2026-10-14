import Foundation

/// The collection or playlist a list queue was started from.
nonisolated struct QueueSource: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case collection
        case playlist
    }

    let id: String
    let kind: Kind
    let name: String
    /// A collection's `DisplayOrder`, so its titles come back in the same
    /// order on another device. Nil for a playlist.
    var displayOrder: String?
}

/// Where the viewer is in one collection or playlist: the entry last started.
/// Whether it is in progress, finished or not begun is read back from the
/// server's watch state, never stored here.
nonisolated struct QueueProgressEntry: Codable, Equatable, Sendable {
    let source: QueueSource
    let position: Int
    /// The title at `position`, to find the entry again if the list changed.
    let itemId: String
}

/// The stored list, newest first, in Lagoon's display preferences on the
/// server (per user and per client, so the TV and the phone share it).
nonisolated enum QueueProgressRecord {
    /// The display-preferences record Lagoon owns.
    static let preferencesID = "lagoon"
    static let preferencesClient = "Lagoon"
    /// The `CustomPrefs` key holding the encoded list.
    static let key = "lagoonQueues"
    static let maximumEntries = 10

    static func entries(in customPrefs: [String: Any]) -> [QueueProgressEntry] {
        guard let encoded = customPrefs[key] as? String,
              let decoded = try? JSONDecoder().decode([QueueProgressEntry].self, from: Data(encoded.utf8))
        else { return [] }
        return decoded
    }

    /// `entry` first, replacing the same list's older one.
    static func recording(_ entry: QueueProgressEntry, in entries: [QueueProgressEntry]) -> [QueueProgressEntry] {
        Array(([entry] + entries.filter { $0.source.id != entry.source.id }).prefix(maximumEntries))
    }

    /// The whole preferences body with only Lagoon's key changed. Jellyfin
    /// resets account-wide settings kept in `CustomPrefs` (skip lengths,
    /// the next-video overlay) to defaults when a write leaves them out, so
    /// every other key goes back exactly as it came.
    static func preferences(_ preferences: [String: Any], storing entries: [QueueProgressEntry]) throws -> [String: Any] {
        var updated = preferences
        var custom = preferences["CustomPrefs"] as? [String: Any] ?? [:]
        let encoded = try JSONEncoder().encode(entries)
        custom[key] = String(decoding: encoded, as: UTF8.self)
        updated["CustomPrefs"] = custom
        updated["Id"] = preferencesID
        updated["Client"] = preferencesClient
        return updated
    }
}
