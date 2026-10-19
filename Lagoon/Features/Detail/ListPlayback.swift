import Foundation

/// What a collection or playlist page's Play button starts: the list as a
/// queue, positioned at the title Play begins with.
struct ListPlayback {
    let queue: PlayQueueList
    /// The starting title is part-watched, so Play reads Resume.
    let resumes: Bool

    /// Movies and episodes in the list's order. A series inside a collection
    /// is skipped rather than expanded. Nil when nothing in it can play.
    ///
    /// Play resumes the part-watched title furthest along, else starts the
    /// first unwatched one, else the first title.
    init?(items: [MediaItem], source: QueueSource? = nil) {
        let playable = items.filter { $0.type == .movie || $0.type == .episode }
        let start: Int
        if let partWatched = playable.lastIndex(where: { $0.playbackProgress != nil }) {
            start = partWatched
            resumes = true
        } else {
            start = playable.firstIndex { $0.userData?.played != true } ?? 0
            resumes = false
        }
        guard let queue = PlayQueueList(
            entries: playable.map { PlayQueueList.Entry(media: $0, playlistItemId: $0.playlistItemId) },
            position: start,
            source: source
        ) else { return nil }
        self.queue = queue
    }

    var title: MediaItem { queue.current.media }

    /// Nil when Play already starts the first title from its first frame.
    var fromBeginning: PlayQueueList? {
        guard resumes || queue.position > 0 else { return nil }
        return PlayQueueList(entries: queue.entries, position: 0, source: queue.source)
    }

    /// Names the title Play starts, and where when it resumes.
    var caption: String {
        let name = [title.railTitle, title.episodeLabel].compactMap { $0 }.joined(separator: " · ")
        guard resumes, let ticks = title.userData?.playbackPositionTicks, ticks > 0 else { return name }
        return String(localized: "\(name), from \(Ticks.timestamp(ticks))")
    }
}
