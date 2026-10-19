import Foundation

/// A title Home draws as part of a list: the queue that continues from it
/// and the label naming where it sits.
struct QueueContext: Equatable {
    /// Positioned at the title.
    let list: PlayQueueList
    /// "Cars Collection · 2 of 3".
    let label: String

    var title: MediaItem { list.current.media }
}

/// What a stored list entry means now, from the server's watch state.
enum QueueProgressResolver {
    enum Outcome: Equatable {
        /// The title is part-watched. Its Continue Watching card continues
        /// the list.
        case inProgress(QueueContext)
        /// Between titles. The next one joins Next Up. `lastPlayed` is when
        /// the list was last watched, as the server wrote it.
        case upNext(QueueContext, lastPlayed: String?)
        /// Nothing left, or the list no longer holds the title.
        case finished
    }

    /// Playable titles as `ListPlayback` counts them, so positions agree.
    static func resolve(_ entry: QueueProgressEntry, items: [MediaItem]) -> Outcome {
        let playable = items.filter { $0.type == .movie || $0.type == .episode }
        let index: Int
        if playable.indices.contains(entry.position), playable[entry.position].id == entry.itemId {
            index = entry.position
        } else if let moved = playable.firstIndex(where: { $0.id == entry.itemId }) {
            index = moved
        } else {
            return .finished
        }

        let title = playable[index]
        let lastPlayed = title.userData?.lastPlayedDate
        if title.playbackProgress != nil {
            return context(at: index, in: playable, entry: entry).map(Outcome.inProgress) ?? .finished
        }
        if title.userData?.played == true {
            guard let next = context(at: index + 1, in: playable, entry: entry) else { return .finished }
            return .upNext(next, lastPlayed: lastPlayed)
        }
        // Started but stopped before the resume threshold: still next.
        guard let current = context(at: index, in: playable, entry: entry) else { return .finished }
        return .upNext(current, lastPlayed: lastPlayed)
    }

    private static func context(at index: Int, in playable: [MediaItem], entry: QueueProgressEntry) -> QueueContext? {
        guard let list = PlayQueueList(
            entries: playable.map { PlayQueueList.Entry(media: $0, playlistItemId: $0.playlistItemId) },
            position: index,
            source: entry.source
        ) else { return nil }
        return QueueContext(list: list, label: "\(entry.source.name) · \(index + 1) of \(playable.count)")
    }

    /// The server's Next Up with the lists' next titles mixed in, most
    /// recently watched first. A server episode takes its show's last-watched
    /// time from `seriesLastPlayed`. Anything without a time keeps its place
    /// after those with one. A title in both appears once.
    static func mergedNextUp(
        server: [MediaItem],
        seriesLastPlayed: [String: String],
        queued: [(title: MediaItem, lastPlayed: String?)]
    ) -> [MediaItem] {
        guard !queued.isEmpty else { return server }
        let candidates: [(item: MediaItem, seconds: Double?)] =
            server.map { item in (item, item.seriesId.flatMap { seriesLastPlayed[$0] }.flatMap(JellyfinTimestamp.seconds)) }
            + queued.map { ($0.title, $0.lastPlayed.flatMap(JellyfinTimestamp.seconds)) }
        let ordered = candidates.enumerated().sorted { lhs, rhs in
            switch (lhs.element.seconds, rhs.element.seconds) {
            case let (l?, r?) where l != r: l > r
            case (_?, nil): true
            case (nil, _?): false
            default: lhs.offset < rhs.offset
            }
        }
        var seen = Set<String>()
        return ordered.map(\.element.item).filter { seen.insert($0.id).inserted }
    }
}
