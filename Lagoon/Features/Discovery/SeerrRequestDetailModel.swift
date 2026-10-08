import Foundation
import Observation

/// The request detail's data and refresh rules: poll only what can change,
/// and keep the last good snapshot through a failure. Outside the view so
/// it can be tested.
@Observable
final class SeerrRequestDetailModel {
    var currentRequest: SeerrMediaRequest
    private(set) var details: SeerrMediaDetails?
    private(set) var jellyfinItem: MediaItem?
    private(set) var qualityProfile: String?
    private(set) var isLoading = true
    var errorMessage: String?
    /// Not `details == nil`: a request without a TMDB id never has details,
    /// and that check showed the error state on every failed poll.
    private(set) var hasLoadedOnce = false
    private var didResolveQualityProfile = false
    private var didResolveAvailableMedia = false

    init(request: SeerrMediaRequest) {
        currentRequest = request
    }

    func load(
        client: SeerrClient,
        jellyfin: JellyfinClient,
        isRefresh: Bool = false
    ) async {
        if !isRefresh { isLoading = true }
        defer {
            if !isRefresh { isLoading = false }
        }
        do {
            let loadedRequest = try await client.request(id: currentRequest.id)
            let loadedDetails = try await mediaDetails(
                for: loadedRequest,
                client: client,
                isRefresh: isRefresh
            )
            let loadedJellyfinItem = await jellyfinItem(
                for: loadedRequest,
                details: loadedDetails,
                jellyfin: jellyfin
            )
            let loadedQualityProfile: String?
            if didResolveQualityProfile {
                loadedQualityProfile = qualityProfile
            } else {
                loadedQualityProfile = await qualityProfile(for: loadedRequest, client: client)
            }
            // Publish one complete snapshot before a cadence change replaces
            // the polling task.
            guard !Task.isCancelled else { return }
            currentRequest = loadedRequest
            details = loadedDetails
            jellyfinItem = loadedJellyfinItem
            qualityProfile = loadedQualityProfile
            didResolveQualityProfile = true
            if Self.isInLibrary(loadedRequest) { didResolveAvailableMedia = true }
            hasLoadedOnce = true
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            // A failed poll must not erase the last percentage or ETA.
            if !isRefresh || !hasLoadedOnce {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Live state rides on the request; TMDB data is static. A poll re-reads
    /// TMDB only when `jellyfinMediaId` appears, which gates "Open in Lagoon".
    private func mediaDetails(
        for request: SeerrMediaRequest,
        client: SeerrClient,
        isRefresh: Bool
    ) async throws -> SeerrMediaDetails? {
        guard let tmdbID = request.tmdbID else { return nil }
        let needsStaticMetadata = !isRefresh
            || details == nil
            || (Self.isInLibrary(request) && !didResolveAvailableMedia)
        guard needsStaticMetadata else { return details }
        return try await client.details(id: tmdbID, mediaType: request.resolvedMediaType)
    }

    /// The profile name comes from the Radarr/Sonarr service, since the
    /// request carries only an id. Best-effort: a miss is just an absent token.
    private func qualityProfile(
        for request: SeerrMediaRequest,
        client: SeerrClient
    ) async -> String? {
        let mediaType = request.resolvedMediaType
        guard mediaType != .person else {
            return nil
        }
        let services = (try? await client.services(mediaType)) ?? []
        guard let source = Self.profileSource(for: request, among: services) else {
            return nil
        }
        let profiles = (try? await client.qualityProfiles(mediaType, serverID: source.serverID)) ?? []
        return profiles.first { $0.id == source.profileID }?.name
    }

    /// The server and profile a request was fulfilled with: the named server,
    /// else the default for its resolution, else any default.
    nonisolated static func profileSource(
        for request: SeerrMediaRequest,
        among services: [SeerrService]
    ) -> (serverID: Int, profileID: Int)? {
        let wants4k = request.is4k == true
        let service = services.first { $0.id == request.serverId }
            ?? services.first { $0.isDefault && $0.is4k == wants4k }
            ?? services.first(where: \.isDefault)

        // `profileId` is set only by an explicit choice (REQUEST_ADVANCED);
        // otherwise the server's active profile applies.
        guard let service, let profileID = request.profileId ?? service.activeProfileId else {
            return nil
        }
        return (service.id, profileID)
    }

    /// Matches like `SeerrMediaDetailView`: Seerr's recorded Jellyfin id,
    /// else an exact TMDB lookup. Once matched, polls keep it.
    private func jellyfinItem(
        for request: SeerrMediaRequest,
        details: SeerrMediaDetails?,
        jellyfin: JellyfinClient
    ) async -> MediaItem? {
        guard Self.isInLibrary(request) else { return nil }
        if let resolved = jellyfinItem { return resolved }
        let jellyfinID = details?.mediaInfo?.jellyfinMediaId
        if let jellyfinID, !jellyfinID.isEmpty {
            return try? await jellyfin.item(id: jellyfinID)
        } else if let tmdbID = request.tmdbID {
            return try? await jellyfin.item(
                tmdbID: tmdbID,
                mediaType: request.resolvedMediaType
            )
        }
        return nil
    }

    private nonisolated static func isInLibrary(_ request: SeerrMediaRequest) -> Bool {
        request.progress == .available || request.progress == .partiallyAvailable
    }
}
