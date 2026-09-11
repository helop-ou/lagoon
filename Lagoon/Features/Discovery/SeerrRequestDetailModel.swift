import Foundation
import Observation

/// The request detail's data and its refresh rules, kept out of the view
/// because HEL-136 states them as behaviour — poll only what can change, and
/// hold the last good snapshot through a transient failure — and behaviour
/// that exists only inside a `View`'s private `@State` cannot be tested.
@Observable
final class SeerrRequestDetailModel {
    var currentRequest: SeerrMediaRequest
    private(set) var details: SeerrMediaDetails?
    private(set) var jellyfinItem: MediaItem?
    private(set) var qualityProfile: String?
    private(set) var isLoading = true
    var errorMessage: String?
    /// Whether the page has ever rendered a good snapshot. Not the same
    /// question as `details == nil`: a request whose media carries no TMDB id
    /// has no details to load at all, so asking about `details` painted the
    /// error state over a perfectly good page on every transient poll failure.
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
            // The cadence can change as this assignment lands. Publish one
            // complete snapshot before SwiftUI replaces the polling task.
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
            // Live refresh is reconciliation, not a new page load. A brief
            // Seerr/Radarr outage must not erase a useful percentage or ETA.
            if !isRefresh || !hasLoadedOnce {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Everything this page shows live — status, percentage, ETA — rides on
    /// the request itself. TMDB supplies title, overview, genres, artwork and
    /// year, none of which change while a request is being watched, so a poll
    /// re-reads TMDB only when it must: `jellyfinMediaId` lands on the media
    /// row when the title reaches the library, and that gates "Open in Lagoon".
    /// Availability flipping therefore buys exactly one more fetch, not one
    /// every ten seconds (HEL-136).
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

    /// Names the quality profile the request was made against. `MediaRequest`
    /// carries only a `profileId`, so the name comes from the Radarr/Sonarr
    /// service; when the request does not say which server, the default one
    /// is the server that would have taken it (HEL-118).
    ///
    /// Best-effort throughout: a missing profile is one absent token, never
    /// an error on a page that is about the request.
    private func qualityProfile(
        for request: SeerrMediaRequest,
        client: SeerrClient
    ) async -> String? {
        let mediaType = request.resolvedMediaType
        guard mediaType != .person else {
            return nil
        }
        let services = (try? await client.services(mediaType)) ?? []
        let wants4k = request.is4k == true
        // The server the request names, else the default one for its
        // resolution, which is the server that would have taken it.
        let service = services.first { $0.id == request.serverId }
            ?? services.first { $0.isDefault && $0.is4k == wants4k }
            ?? services.first(where: \.isDefault)

        // `profileId` is only set when the requester explicitly chose one,
        // which needs REQUEST_ADVANCED and is rare. Everything else inherits
        // the server's active profile, and *that* is what an approver is
        // agreeing to fetch.
        guard let profileID = request.profileId ?? service?.activeProfileId,
              let serverID = service?.id
        else {
            return nil
        }
        let profiles = (try? await client.qualityProfiles(mediaType, serverID: serverID)) ?? []
        return profiles.first { $0.id == profileID }?.name
    }

    /// A request whose title has arrived should be playable from here rather
    /// than only removable — the same match `SeerrMediaDetailView` makes, and
    /// on the same terms: the Jellyfin id Seerr recorded when it can, an
    /// exact TMDB lookup when it cannot (HEL-115). Once matched, the item is
    /// as static as the artwork, so a poll keeps the one it already has.
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

    /// Whether the title is playable to any degree, which is what makes the
    /// Jellyfin id worth resolving.
    private nonisolated static func isInLibrary(_ request: SeerrMediaRequest) -> Bool {
        request.progress == .available || request.progress == .partiallyAvailable
    }
}
