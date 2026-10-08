import Foundation
import Observation

/// A Seerr title page's data and refresh rules: a poll re-reads the live
/// state and leaves the static recommendations alone, and a failed poll
/// keeps the last good details. Outside the view so it can be tested.
@Observable
final class SeerrMediaDetailModel {
    let mediaID: Int
    let mediaType: SeerrMediaType
    private(set) var details: SeerrMediaDetails?
    private(set) var jellyfinItem: MediaItem?
    private(set) var recommendations: [SeerrDiscoverResult] = []
    private(set) var isLoading = true
    var errorMessage: String?

    init(mediaID: Int, mediaType: SeerrMediaType) {
        self.mediaID = mediaID
        self.mediaType = mediaType
    }

    func load(client: SeerrClient, jellyfin: JellyfinClient, isRefresh: Bool = false) async {
        if !isRefresh {
            isLoading = true
            errorMessage = nil
        }
        defer {
            if !isRefresh { isLoading = false }
        }
        do {
            // Static metadata: the live refresh leaves recommendations alone.
            async let loadedRecommendations: [SeerrDiscoverResult]? = isRefresh
                ? nil
                : (try? await client.recommendations(id: mediaID, mediaType: mediaType))?.results
            let loaded = try await client.details(id: mediaID, mediaType: mediaType)
            let loadedJellyfinItem: MediaItem?
            if loaded.mediaInfo?.availability == .available || loaded.mediaInfo?.availability == .partiallyAvailable {
                if let jellyfinID = loaded.mediaInfo?.jellyfinMediaId, !jellyfinID.isEmpty {
                    loadedJellyfinItem = try? await jellyfin.item(id: jellyfinID)
                } else {
                    loadedJellyfinItem = try? await jellyfin.item(
                        tmdbID: mediaID,
                        mediaType: mediaType
                    )
                }
            } else {
                loadedJellyfinItem = nil
            }
            let newRecommendations = await loadedRecommendations
            // Commit one coherent snapshot, never half of a terminal transition
            // that cancels the polling task.
            guard !Task.isCancelled else { return }
            details = loaded
            jellyfinItem = loadedJellyfinItem
            if !isRefresh {
                recommendations = (newRecommendations ?? []).filter { $0.mediaType == .movie || $0.mediaType == .tv }
            }
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            // A failed poll keeps the last progress and retries next interval.
            if details == nil { errorMessage = error.localizedDescription }
        }
    }

    /// A show with seasons nobody has asked for yet, and a viewer allowed to
    /// ask for them.
    nonisolated static func canRequestMoreSeasons(
        _ details: SeerrMediaDetails,
        mediaType: SeerrMediaType,
        user: SeerrUser?,
        includingSpecials: Bool
    ) -> Bool {
        mediaType == .tv
            && user?.canRequest(.tv) == true
            && !details.requestableSeasons(includingSpecials: includingSpecials).isEmpty
    }
}
