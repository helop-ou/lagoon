import SwiftUI

/// A Seerr title's page: the same composition as a library title's
/// (`DetailPageScaffold`, `DetailMetadataHeader`, `DetailActionLayout`,
/// `CastStrip`), with Seerr's request state where a library title has Play
/// (HEL-174). The artwork is TMDB's: posters and backdrops through Seerr,
/// the title logo through `TMDBLogoProvider`, or the Jellyfin server's own
/// logo once the title is in the library.
struct SeerrMediaDetailView: View {
    let mediaID: Int
    let mediaType: SeerrMediaType

    @Environment(SessionStore.self) private var session
    @Environment(SeerrSessionStore.self) private var seerr
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @State private var details: SeerrMediaDetails?
    @State private var jellyfinItem: MediaItem?
    @State private var recommendations: [SeerrDiscoverResult] = []
    @State private var logoPath: String?
    @State private var isLoading = true
    @State private var isRequesting = false
    @State private var errorMessage: String?
    @State private var popup: Popup?
    @State private var seasonRequestDetails: SeerrMediaDetails?
    @State private var reloadID = 0

    var body: some View {
        Group {
            if isLoading, details == nil {
                LoadingView()
            } else if let errorMessage, details == nil {
                ErrorStateView(message: errorMessage) { reloadID += 1 }
            } else if let details {
                DetailPageScaffold(
                    backdropURL: SeerrClient.imageURL(path: details.backdropPath, width: Metrics.detailBackdropRequestWidth),
                    posterURL: SeerrClient.imageURL(path: details.posterPath, width: Metrics.detailPosterRequestWidth)
                ) {
                    DetailMetadataHeader(
                        subtitle: details.tagline,
                        factTokens: factTokens(details),
                        officialRating: details.officialRating(),
                        genres: details.genres?.map(\.name) ?? [],
                        communityRating: displayRating(details.voteAverage),
                        overview: details.overview
                    ) {
                        titleArt(details)
                    } buttons: {
                        DetailActionLayout {
                            primaryAction(details)
                        } secondary: {
                            secondaryActions(details)
                        }
                    }
                    CastStrip(credits: castCredits(details))
                    if !recommendations.isEmpty {
                        SeerrMediaRail(title: String(localized: "More Like This"), items: recommendations)
                    }
                }
            }
        }
        .task(id: reloadID) { await load() }
        .seerrLiveRefreshable(
            cadence: SeerrLiveRefreshCadence.mediaDetails(details),
            isPaused: isLoading || isRequesting || seasonRequestDetails != nil
        ) {
            await load(isRefresh: true)
        }
        .alert(popup?.title ?? "Seerr", isPresented: Binding(
            get: { popup != nil },
            set: { if !$0 { popup = nil } }
        )) {
            if popup?.confirmsMovieRequest == true {
                Button("Cancel", role: .cancel) { popup = nil }
                Button("Request Movie") {
                    popup = nil
                    requestMovie()
                }
            } else if popup?.confirmsUnblock == true {
                Button("Cancel", role: .cancel) { popup = nil }
                Button("Unblock") {
                    popup = nil
                    unblock()
                }
            } else {
                Button("OK") { popup = nil }
            }
        } message: {
            Text(popup?.message ?? "")
        }
        .sheet(item: $seasonRequestDetails, onDismiss: { reloadID += 1 }) { details in
            NavigationStack {
                SeerrSeasonRequestView(details: details)
            }
            .presentationSizing(.form)
        }
        .accessibilityIdentifier("seerr.detail.\(mediaType.rawValue).\(mediaID)")
    }

    /// The title as artwork where anyone has it: the Jellyfin server's logo
    /// once the title is in the library, TMDB's otherwise, and the name in
    /// type when neither has one — the same fallback a library title makes.
    private func titleArt(_ details: SeerrMediaDetails) -> some View {
        #if os(iOS)
        let alignment = DetailLayout.titleAlignment(horizontalSizeClass, verticalSizeClass)
        #else
        let alignment: HorizontalAlignment = .leading
        #endif
        return TitleArtImage(
            url: titleArtURL,
            title: details.displayTitle,
            alignment: alignment
        )
    }

    private var titleArtURL: URL? {
        if let jellyfinItem,
           let url = session.client.imageURL(for: jellyfinItem, kind: .logo, maxWidth: Int(Metrics.logoMaxWidth * 2)) {
            return url
        }
        return SeerrClient.imageURL(path: logoPath, width: Int(Metrics.logoMaxWidth * 2))
    }

    /// Actors in billing order, then the crew TMDB lists; the strip itself
    /// drops anyone without a picture.
    private func castCredits(_ details: SeerrMediaDetails) -> [CastCredit] {
        guard let credits = details.credits else { return [] }
        let portraitWidth = Int(Metrics.castPortraitSize * 2)
        let cast = credits.cast
            .sorted { ($0.order ?? .max) < ($1.order ?? .max) }
            .map { member in
                CastCredit(
                    id: member.creditId,
                    name: member.name ?? "",
                    credit: member.character.flatMap { $0.isEmpty ? nil : $0 },
                    imageURL: SeerrClient.imageURL(path: member.profilePath, width: portraitWidth)
                )
            }
        let crew = credits.crew.map { member in
            CastCredit(
                id: member.creditId,
                name: member.name ?? "",
                credit: member.job.flatMap { $0.isEmpty ? nil : $0 } ?? member.department,
                imageURL: SeerrClient.imageURL(path: member.profilePath, width: portraitWidth)
            )
        }
        return cast + crew
    }

    /// What the page is for: opening the title in the library when it is
    /// there, asking for it when it is not, and otherwise saying where the
    /// request has got to. Styled as the library page styles Play.
    @ViewBuilder
    private func primaryAction(_ details: SeerrMediaDetails) -> some View {
        switch availability {
        case .available:
            if let jellyfinItem {
                openInLagoonButton(jellyfinItem)
            } else {
                statusButton(
                    title: "Available in Jellyfin",
                    symbol: "checkmark.circle.fill",
                    message: "Seerr reports this title as available, but Lagoon couldn't match it to an item in your current Jellyfin library."
                )
            }
        case .pending, .processing:
            // When the server knows how far the download has got, the button
            // says so rather than a bare "Processing" (HEL-116).
            if availability == .processing, let progress = details.mediaInfo?.downloadProgress() {
                statusButton(
                    title: progress.isImporting ? String(localized: "Importing") : progress.percentText,
                    symbol: progress.isImporting ? "square.and.arrow.down" : "arrow.down.circle",
                    message: progress.downloadCount > 1
                        ? "\(progress.summary). \(progress.downloadCount) downloads."
                        : progress.summary,
                    motion: .bounce
                )
            } else {
                statusButton(
                    title: availability.title,
                    symbol: availability == .pending ? "clock" : "arrow.triangle.2.circlepath",
                    message: availability == .pending
                        ? "This request is waiting for approval."
                        : "This title has been approved and is being added to your library.",
                    motion: availability == .pending ? .pulse : .rotate
                )
            }
        case .partiallyAvailable:
            if let jellyfinItem {
                openInLagoonButton(jellyfinItem)
            } else if canRequestMoreSeasons {
                requestMoreSeasonsButton(details, isPrimary: true)
            } else {
                partiallyAvailableStatusButton
            }
        case .blocklisted:
            // An administrator who can lift the block should be able to do it
            // here rather than reaching for the web UI (HEL-115). Jellyseerr
            // drops the media row along with the blocklist entry, so the
            // reload afterwards shows the ordinary Request button.
            if seerr.user?.canManageBlocklist == true {
                Button {
                    popup = Popup(
                        title: "Unblock \(details.displayTitle)?",
                        message: "This lifts the block so the title can be requested again.",
                        confirmsUnblock: true
                    )
                } label: {
                    if isRequesting {
                        ProgressView()
                    } else {
                        Label("Unblock", systemImage: "hand.raised.slash")
                            .detailPrimaryLabel()
                    }
                }
                .detailPrimaryButton()
                .disabled(isRequesting)
                .accessibilityIdentifier("seerr.detail.unblock")
            } else {
                statusButton(
                    title: availability.title,
                    symbol: "hand.raised",
                    message: "The server administrator has blocked this title, so it cannot be requested."
                )
            }
        case .unknown, .deleted:
            if seerr.user?.canRequest(mediaType) == true {
                if mediaType == .movie {
                    Button {
                        popup = Popup(
                            title: "Request \(details.displayTitle)?",
                            message: "Send this movie request to Seerr?",
                            confirmsMovieRequest: true
                        )
                    } label: {
                        if isRequesting {
                            ProgressView()
                        } else {
                            Label("Request Movie", systemImage: "plus")
                                .detailPrimaryLabel()
                        }
                    }
                    .detailPrimaryButton()
                    .disabled(isRequesting)
                    .accessibilityIdentifier("seerr.detail.request")
                } else {
                    Button {
                        seasonRequestDetails = details
                    } label: {
                        Label("Choose Seasons", systemImage: "plus")
                            .detailPrimaryLabel()
                    }
                    .detailPrimaryButton()
                    .accessibilityIdentifier("seerr.detail.request")
                }
            } else {
                statusButton(
                    title: "Request Unavailable",
                    symbol: "lock",
                    message: "Your Seerr account doesn't have permission to request this title."
                )
            }
        }
    }

    /// Beside Open in Lagoon on a partly available show: the way to ask
    /// for the rest of it, or the fact that only some of it is here.
    @ViewBuilder
    private func secondaryActions(_ details: SeerrMediaDetails) -> some View {
        if availability == .partiallyAvailable, jellyfinItem != nil {
            if canRequestMoreSeasons {
                requestMoreSeasonsButton(details)
            } else {
                partiallyAvailableStatusButton
            }
        }
    }

    private func openInLagoonButton(_ item: MediaItem) -> some View {
        NavigationLink(value: SeerrNavigationRoute.jellyfinItem(item)) {
            Label("Open in Lagoon", systemImage: "play.fill")
                .detailPrimaryLabel()
        }
        .detailPrimaryButton()
        .accessibilityIdentifier("seerr.detail.open")
    }

    private var canRequestMoreSeasons: Bool {
        mediaType == .tv && seerr.user?.canRequest(.tv) == true
    }

    /// The page's one big button when nothing is playable yet; a plain
    /// glass pill beside Open in Lagoon otherwise.
    @ViewBuilder
    private func requestMoreSeasonsButton(_ details: SeerrMediaDetails, isPrimary: Bool = false) -> some View {
        let button = Button {
            seasonRequestDetails = details
        } label: {
            if isPrimary {
                Label("Request More Seasons", systemImage: "plus")
                    .detailPrimaryLabel()
            } else {
                Label("Request More Seasons", systemImage: "plus")
            }
        }
        .accessibilityIdentifier("seerr.detail.request")
        if isPrimary {
            button.detailPrimaryButton()
        } else {
            button.buttonStyle(.glass)
        }
    }

    private var partiallyAvailableStatusButton: some View {
        statusButton(
            title: availability.title,
            symbol: "circle.lefthalf.filled",
            message: "Some of this title is already available in your Jellyfin library."
        )
    }

    private func statusButton(
        title: String,
        symbol: String,
        message: String,
        motion: SeerrStatusMotion = .still
    ) -> some View {
        Button {
            popup = Popup(title: title, message: message)
        } label: {
            SeerrStatusLabel(title: title, symbol: symbol, motion: motion)
                .detailPrimaryLabel()
        }
        .detailPrimaryButton()
    }

    private var availability: SeerrAvailabilityStatus {
        details?.mediaInfo?.availability ?? .unknown
    }

    private func load(isRefresh: Bool = false) async {
        if !isRefresh {
            isLoading = true
            errorMessage = nil
        }
        defer {
            if !isRefresh { isLoading = false }
        }
        do {
            // The recommendations and the logo describe the title, not its
            // request state, so the first load fetches them alongside the
            // details and the live refresh leaves them alone.
            async let loadedRecommendations: [SeerrDiscoverResult]? = isRefresh
                ? nil
                : (try? await seerr.client.recommendations(id: mediaID, mediaType: mediaType))?.results
            async let loadedLogoPath: String? = isRefresh
                ? nil
                : await TMDBLogoProvider.shared.logoPath(id: mediaID, mediaType: mediaType)
            let loaded = try await seerr.client.details(id: mediaID, mediaType: mediaType)
            let loadedJellyfinItem: MediaItem?
            if loaded.mediaInfo?.availability == .available || loaded.mediaInfo?.availability == .partiallyAvailable {
                if let jellyfinID = loaded.mediaInfo?.jellyfinMediaId, !jellyfinID.isEmpty {
                    loadedJellyfinItem = try? await session.client.item(id: jellyfinID)
                } else {
                    loadedJellyfinItem = try? await session.client.item(
                        tmdbID: mediaID,
                        mediaType: mediaType
                    )
                }
            } else {
                loadedJellyfinItem = nil
            }
            let (newRecommendations, newLogoPath) = await (loadedRecommendations, loadedLogoPath)
            // Commit one coherent snapshot. If changing cadence cancels the
            // polling task, the page has already received every value from
            // this response rather than half of a terminal transition.
            guard !Task.isCancelled else { return }
            details = loaded
            jellyfinItem = loadedJellyfinItem
            if !isRefresh {
                recommendations = (newRecommendations ?? []).filter { $0.mediaType == .movie || $0.mediaType == .tv }
                logoPath = newLogoPath
            }
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            // A transient poll failure is not a page state. Keep the last
            // useful percentage/ETA and try again on the next cadence.
            if details == nil { errorMessage = error.localizedDescription }
        }
    }

    private func unblock() {
        isRequesting = true
        Task {
            defer { isRequesting = false }
            do {
                try await seerr.client.removeFromBlocklist(tmdbID: mediaID, mediaType: mediaType)
                // The media row goes with the block, so re-reading is what
                // turns the page back into an ordinary requestable title.
                reloadID += 1
            } catch {
                popup = Popup(
                    title: String(localized: "Couldn't Unblock"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func requestMovie() {
        guard !isRequesting else { return }
        isRequesting = true
        errorMessage = nil
        Task {
            do {
                let request = try await seerr.client.createRequest(SeerrCreateRequest(
                    mediaType: .movie,
                    mediaId: mediaID,
                    seasons: nil,
                    is4k: false
                ))
                popup = Popup(
                    title: "Request Sent",
                    message: "Your request is now \(request.requestStatus.title.lowercased())."
                )
                reloadID += 1
            } catch {
                popup = Popup(
                    title: "Couldn't Send Request",
                    message: error.localizedDescription
                )
            }
            isRequesting = false
        }
    }

    private func factTokens(_ details: SeerrMediaDetails) -> [String] {
        [runtimeText(details), details.year].compactMap { $0 }
    }

    private func displayRating(_ rating: Double?) -> Double? {
        guard let rating, rating > 0 else { return nil }
        return rating
    }

    private func runtimeText(_ details: SeerrMediaDetails) -> String? {
        let minutes = details.runtime ?? details.episodeRunTime?.first
        guard let minutes, minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    private struct Popup {
        let title: String
        let message: String
        var confirmsMovieRequest = false
        var confirmsUnblock = false
    }
}

struct SeerrSeasonRequestView: View {
    let details: SeerrMediaDetails
    @Environment(\.dismiss) private var dismiss
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var selected: Set<Int> = []
    @State private var isRequesting = false
    @State private var isConfirmingRequest = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Button {
                    selectAllOrClear()
                } label: {
                    Text(allSelectableSeasonsAreSelected ? "Clear Selection" : "Select All Available")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                #if os(tvOS)
                .buttonStyle(.glass)
                #else
                .buttonStyle(.borderless)
                #endif
                .disabled(selectableSeasons.isEmpty || isRequesting)
            }

            Section(details.displayTitle) {
                ForEach(visibleSeasons) { season in
                    let selectable = isSelectable(season)
                    Button {
                        toggle(season)
                    } label: {
                        HStack(spacing: Metrics.Space.l) {
                            VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                                Text(season.displayName)
                                    .font(.headline)
                                if let count = season.episodeCount {
                                    Text(count == 1 ? "1 episode" : "\(count) episodes")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            selectionAccessory(for: season, selectable: selectable)
                        }
                        .contentShape(Rectangle())
                    }
                    #if os(tvOS)
                    .buttonStyle(.glass)
                    #else
                    .buttonStyle(.borderless)
                    #endif
                    .disabled(!selectable || isRequesting)
                    .accessibilityValue(selectionValue(for: season, selectable: selectable))
                    .accessibilityIdentifier("seerr.season.\(season.seasonNumber)")
                }
            }
        }
        .navigationTitle("Choose Seasons")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    isConfirmingRequest = true
                } label: {
                    if isRequesting {
                        ProgressView()
                    } else {
                        Text("Request \(selected.count)")
                    }
                }
                .disabled(selected.isEmpty || isRequesting)
                .accessibilityLabel("Request \(selected.count) Season\(selected.count == 1 ? "" : "s")")
                .accessibilityIdentifier("seerr.seasons.submit")
            }
        }
        .confirmationDialog(
            "Request \(selected.count) Season\(selected.count == 1 ? "" : "s")?",
            isPresented: $isConfirmingRequest,
            titleVisibility: .visible
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Send Request") { submit() }
        } message: {
            Text("Send a request for the selected season\(selected.count == 1 ? "" : "s") of \(details.displayTitle)?")
        }
        .alert("Couldn't Send Request", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The request couldn't be sent.")
        }
        .accessibilityIdentifier("seerr.seasons")
    }

    private var visibleSeasons: [SeerrSeason] {
        (details.seasons ?? []).filter {
            $0.seasonNumber > 0 || seerr.publicSettings?.enableSpecialEpisodes == true
        }
    }

    private var selectableSeasons: [SeerrSeason] { visibleSeasons.filter(isSelectable) }

    private var allSelectableSeasonsAreSelected: Bool {
        !selectableSeasons.isEmpty && selected.count == selectableSeasons.count
    }

    private func toggle(_ season: SeerrSeason) {
        if selected.contains(season.seasonNumber) {
            selected.remove(season.seasonNumber)
        } else {
            selected.insert(season.seasonNumber)
        }
    }

    private func selectAllOrClear() {
        if allSelectableSeasonsAreSelected {
            selected.removeAll()
        } else {
            selected = Set(selectableSeasons.map(\.seasonNumber))
        }
    }

    @ViewBuilder
    private func selectionAccessory(for season: SeerrSeason, selectable: Bool) -> some View {
        if selected.contains(season.seasonNumber) {
            Image(systemName: "checkmark")
                .font(.headline)
                .foregroundStyle(.tint)
        } else if selectable {
            Image(systemName: "checkmark")
                .font(.headline)
                .hidden()
        } else {
            Label(seasonState(season), systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func selectionValue(for season: SeerrSeason, selectable: Bool) -> String {
        if selected.contains(season.seasonNumber) { return "Selected" }
        return selectable ? "Not selected" : seasonState(season)
    }

    private func isSelectable(_ season: SeerrSeason) -> Bool {
        let available = details.mediaInfo?.seasons?.first(where: {
            $0.seasonNumber == season.seasonNumber
        })?.availability == .available
        let requested = details.mediaInfo?.requests?.contains(where: { request in
            request.requestStatus != .declined
                && (request.seasons?.contains { $0.seasonNumber == season.seasonNumber } == true)
        }) == true
        return !available && !requested
    }

    private func seasonState(_ season: SeerrSeason) -> String {
        if details.mediaInfo?.seasons?.first(where: { $0.seasonNumber == season.seasonNumber })?.availability == .available {
            return "Available"
        }
        return "Requested"
    }

    private func submit() {
        guard !selected.isEmpty, !isRequesting else { return }
        isRequesting = true
        errorMessage = nil
        Task {
            do {
                _ = try await seerr.client.createRequest(SeerrCreateRequest(
                    mediaType: .tv,
                    mediaId: details.id,
                    seasons: selected.sorted(),
                    is4k: false
                ))
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isRequesting = false
            }
        }
    }
}
