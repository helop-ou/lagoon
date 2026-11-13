import Foundation
import Observation

/// What sits beside the playing title for the player's own buttons: the
/// title before it, and what the Episodes button lists. A list queue answers
/// both itself. A series asks the server.
@Observable
@MainActor
final class PlayerNeighbours {
    /// The episode or list entry before this one, for the previous button.
    private(set) var previousItem: MediaItem?
    /// What the Episodes button lists. Kept across a hand-off, so the list
    /// stays up while the next title starts.
    private(set) var episodeList: PlayerEpisodeList?
    @ObservationIgnored private var previousItemTask: Task<Void, Never>?
    @ObservationIgnored private var episodeListTask: Task<Void, Never>?
    /// Seasons already fetched for the Episodes list, for the player's life.
    @ObservationIgnored private var seasonEpisodes: [String: [MediaItem]] = [:]

    func resolve(around media: MediaItem, queue: PlayQueue, client: JellyfinClient) {
        resolvePreviousItem(before: media, queue: queue, client: client)
        resolveEpisodeList(for: media, queue: queue, client: client)
    }

    /// For a hand-off: the title before the outgoing one is not the one
    /// before the incoming one.
    func forgetPreviousItem() {
        previousItem = nil
    }

    func cancel() {
        previousItemTask?.cancel()
        previousItemTask = nil
        episodeListTask?.cancel()
        episodeListTask = nil
    }

    private func resolveEpisodeList(for media: MediaItem, queue: PlayQueue, client: JellyfinClient) {
        episodeListTask?.cancel()
        switch PlayerEpisodeList.source(for: media, queue: queue) {
        case .none:
            episodeList = nil
        case .queue(let list):
            episodeList = .queue(list)
        case .season(let seriesId, let seasonId):
            if let episodes = seasonEpisodes[seasonId] {
                episodeList = .season(episodes, current: media)
                return
            }
            episodeList = nil
            episodeListTask = Task { [weak self] in
                guard let episodes = try? await client.episodes(seriesId: seriesId, seasonId: seasonId),
                      !Task.isCancelled, let self else { return }
                self.seasonEpisodes[seasonId] = episodes
                self.episodeList = .season(episodes, current: media)
            }
        }
    }

    private func resolvePreviousItem(before media: MediaItem, queue: PlayQueue, client: JellyfinClient) {
        previousItemTask?.cancel()
        previousItem = nil
        switch queue.predecessor(before: media) {
        case .none:
            break
        case .entry(let previous):
            previousItem = previous
        case .previousEpisode:
            previousItemTask = Task { [weak self] in
                let previous = try? await client.episodeBefore(media)
                guard !Task.isCancelled else { return }
                self?.previousItem = previous
            }
        }
    }
}
