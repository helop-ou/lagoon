import Foundation

/// What plays after the current title.
nonisolated enum PlayQueue: Equatable {
    /// The server picks the next episode, as it always has. Nothing follows
    /// a movie.
    case series
    /// A fixed sequence, a collection or a playlist, which may mix movies
    /// and episodes.
    case list(PlayQueueList)

    /// Where the title after `media` comes from.
    nonisolated enum Successor: Equatable {
        case none
        /// Ask the server for the episode after this one.
        case nextEpisode
        case entry(MediaItem)
    }

    func successor(after media: MediaItem) -> Successor {
        switch self {
        case .series:
            media.type == .episode ? .nextEpisode : .none
        case .list(let list):
            list.next.map { .entry($0.media) } ?? .none
        }
    }

    /// The queue once its next entry is playing. A series queue has no
    /// position to move.
    func advanced() -> PlayQueue {
        guard case .list(let list) = self, let advanced = list.advanced() else { return self }
        return .list(advanced)
    }

    /// In a list, the Up Next countdown waits for the end of the file
    /// rather than starting at the credits, so a scene after them survives.
    var countdownWaitsForEnd: Bool {
        if case .list = self { true } else { false }
    }
}

/// A collection's or playlist's titles in play order, and which one is
/// playing. Entries are told apart by position, never by title, because a
/// playlist can hold the same title twice.
nonisolated struct PlayQueueList: Equatable {
    nonisolated struct Entry: Equatable {
        let media: MediaItem
        /// The playlist's own id for this entry. Nil in a collection.
        var playlistItemId: String?
    }

    let entries: [Entry]
    private(set) var position: Int

    /// Nil when `position` is outside `entries`.
    init?(entries: [Entry], position: Int = 0) {
        guard entries.indices.contains(position) else { return nil }
        self.entries = entries
        self.position = position
    }

    var current: Entry { entries[position] }

    var next: Entry? {
        entries.indices.contains(position + 1) ? entries[position + 1] : nil
    }

    /// Nil at the last entry.
    func advanced() -> PlayQueueList? {
        guard next != nil else { return nil }
        var advanced = self
        advanced.position += 1
        return advanced
    }
}
