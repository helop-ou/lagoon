import Foundation

/// What the player's Episodes button lists: the current season of a series,
/// or every entry of a collection or playlist, with the playing one marked.
nonisolated struct PlayerEpisodeList: Equatable {
    struct Row: Equatable, Identifiable {
        /// The position in the list. A playlist can hold one title twice, so
        /// the media id is not unique.
        let index: Int
        let media: MediaItem
        let title: String
        /// The series, where the list mixes titles.
        let detail: String?
        let isCurrent: Bool

        var id: Int { index }
    }

    let heading: String?
    let rows: [Row]

    var current: Row? { rows.first(where: \.isCurrent) }

    /// Where the list for `media` comes from.
    enum Source: Equatable {
        case none
        /// Ask the server for the season's episodes.
        case season(seriesId: String, seasonId: String)
        case queue(PlayQueueList)
    }

    static func source(for media: MediaItem, queue: PlayQueue) -> Source {
        switch queue {
        case .list(let list):
            return .queue(list)
        case .series:
            guard let seriesId = media.seriesId, let seasonId = media.seasonId else {
                return .none
            }
            return .season(seriesId: seriesId, seasonId: seasonId)
        }
    }

    /// Nil without a row for the playing episode: a list that does not hold
    /// it would mark nothing and could not be trusted to be its season.
    static func season(_ episodes: [MediaItem], current: MediaItem) -> PlayerEpisodeList? {
        guard episodes.contains(where: { $0.id == current.id }) else { return nil }
        let season = current.parentIndexNumber.map {
            $0 == 0 ? String(localized: "Specials") : String(localized: "Season \($0)")
        }
        let heading = [current.seriesName, season].compactMap(\.self).joined(separator: " · ")
        let rows = episodes.enumerated().map { index, episode in
            Row(
                index: index,
                media: episode,
                title: title(for: episode),
                detail: nil,
                isCurrent: episode.id == current.id
            )
        }
        return PlayerEpisodeList(heading: heading.isEmpty ? nil : heading, rows: rows)
    }

    /// Every entry, the series named on episodes since the list mixes them.
    static func queue(_ list: PlayQueueList) -> PlayerEpisodeList {
        let rows = list.entries.enumerated().map { index, entry in
            Row(
                index: index,
                media: entry.media,
                title: title(for: entry.media),
                detail: entry.media.type == .episode ? entry.media.seriesName : nil,
                isCurrent: index == list.position
            )
        }
        return PlayerEpisodeList(heading: nil, rows: rows)
    }

    /// "S4 E2 · Five Minutes", or the plain name for anything but an episode.
    static func title(for media: MediaItem) -> String {
        let parts = [media.episodeLabel, media.name].compactMap(\.self)
        return parts.isEmpty ? String(localized: "Untitled") : parts.joined(separator: " · ")
    }
}
