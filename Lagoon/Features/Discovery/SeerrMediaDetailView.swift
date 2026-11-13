import SwiftUI

/// A Seerr title's page, composed like a library title's, with request
/// state where Play would be. TMDB artwork via Seerr. The Jellyfin logo once
/// the title is in the library.
struct SeerrMediaDetailView: View {
    @Environment(\.displayScale) private var displayScale
    let mediaID: Int
    let mediaType: SeerrMediaType

    @Environment(SessionStore.self) private var session
    @Environment(SeerrSessionStore.self) private var seerr
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @State private var model: SeerrMediaDetailModel
    @State private var isRequesting = false
    @State private var popup: Popup?
    @State private var seasonRequestDetails: SeerrMediaDetails?
    @State private var reloadID = 0

    init(mediaID: Int, mediaType: SeerrMediaType) {
        self.mediaID = mediaID
        self.mediaType = mediaType
        _model = State(initialValue: SeerrMediaDetailModel(mediaID: mediaID, mediaType: mediaType))
    }

    /// Over a model that has already loaded, so a snapshot draws the page.
    init(model: SeerrMediaDetailModel) {
        mediaID = model.mediaID
        mediaType = model.mediaType
        _model = State(initialValue: model)
    }

    private var jellyfinItem: MediaItem? { model.jellyfinItem }

    var body: some View {
        Group {
            if model.isLoading, model.details == nil {
                LoadingView()
            } else if let errorMessage = model.errorMessage, model.details == nil {
                ErrorStateView(message: errorMessage) { reloadID += 1 }
            } else if let details = model.details {
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
                    if !model.recommendations.isEmpty {
                        SeerrMediaRail(title: String(localized: "More Like This"), items: model.recommendations)
                    }
                }
            }
        }
        .task(id: reloadID) { await load() }
        .seerrLiveRefreshable(
            cadence: SeerrLiveRefreshCadence.mediaDetails(model.details),
            isPaused: model.isLoading || isRequesting || seasonRequestDetails != nil
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
            #if os(tvOS)
            SeerrSeasonRequestView(details: details)
            #else
            NavigationStack {
                SeerrSeasonRequestView(details: details)
            }
            .presentationSizing(.form)
            #endif
        }
        .accessibilityIdentifier("seerr.detail.\(mediaType.rawValue).\(mediaID)")
    }

    /// The Jellyfin logo when there is one, else the title in type.
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
           let url = session.client.imageURL(for: jellyfinItem, kind: .logo, maxWidth: ArtworkSizing.pixels(for: Metrics.logoMaxWidth, displayScale: displayScale)) {
            return url
        }
        return nil
    }

    /// Cast in billing order, then crew. The strip drops anyone without a picture.
    private func castCredits(_ details: SeerrMediaDetails) -> [CastCredit] {
        guard let credits = details.credits else { return [] }
        let portraitWidth = ArtworkSizing.pixels(for: Metrics.castPortraitSize, displayScale: displayScale)
        let cast = credits.cast
            .sorted { ($0.order ?? .max) < ($1.order ?? .max) }
            .map { member in
                CastCredit(
                    id: member.creditId,
                    name: member.name ?? "",
                    credit: member.character.flatMap { $0.isEmpty ? nil : $0 },
                    imageURL: SeerrClient.imageURL(path: member.profilePath, width: portraitWidth),
                    tmdbPerson: Self.person(id: member.id, name: member.name, profilePath: member.profilePath)
                )
            }
        let crew = credits.crew.map { member in
            CastCredit(
                id: member.creditId,
                name: member.name ?? "",
                credit: member.job.flatMap { $0.isEmpty ? nil : $0 } ?? member.department,
                imageURL: SeerrClient.imageURL(path: member.profilePath, width: portraitWidth),
                tmdbPerson: Self.person(id: member.id, name: member.name, profilePath: member.profilePath)
            )
        }
        return cast + crew
    }

    /// The person a credit opens. A missing TMDB id decodes as 0, which
    /// opens nothing.
    nonisolated static func person(id: Int, name: String?, profilePath: String?) -> SeerrPerson? {
        guard id > 0, let name, !name.isEmpty else { return nil }
        return SeerrPerson(id: id, name: name, profilePath: profilePath)
    }

    /// Open in Lagoon, Request, or the request's status, styled like Play.
    @ViewBuilder
    private func primaryAction(_ details: SeerrMediaDetails) -> some View {
        if let action = SeerrPrimaryAction.resolve(primaryContext(details)) {
            primaryButton(action, details)
        } else if let jellyfinItem {
            openInLagoonButton(jellyfinItem)
        }
    }

    private func primaryContext(_ details: SeerrMediaDetails) -> SeerrPrimaryAction.Context {
        SeerrPrimaryAction.Context(
            availability: availability,
            mediaType: mediaType,
            isInLibrary: jellyfinItem != nil,
            canRequest: seerr.user?.canRequest(mediaType) == true,
            canManageBlocklist: seerr.user?.canManageBlocklist == true,
            canRequestMoreSeasons: canRequestMoreSeasons(details),
            downloadProgress: details.mediaInfo?.downloadProgress()
        )
    }

    /// One button for every state, never disabled: the request it sends
    /// changes what it says, and the focus stays on it.
    private func primaryButton(_ action: SeerrPrimaryAction, _ details: SeerrMediaDetails) -> some View {
        Button {
            guard !isRequesting else { return }
            perform(action, details)
        } label: {
            if isRequesting {
                ProgressView()
            } else {
                SeerrStatusLabel(title: action.title, symbol: action.symbol, motion: action.motion)
                    .detailPrimaryLabel()
            }
        }
        .detailPrimaryButton()
        .accessibilityIdentifier(action.identifier)
    }

    private func perform(_ action: SeerrPrimaryAction, _ details: SeerrMediaDetails) {
        switch action.tap {
        case .explain(let message):
            popup = Popup(title: action.title, message: message)
        case .confirmMovieRequest:
            popup = Popup(
                title: "Request \(details.displayTitle)?",
                message: "Send this movie request to Seerr?",
                confirmsMovieRequest: true
            )
        case .confirmUnblock:
            popup = Popup(
                title: "Unblock \(details.displayTitle)?",
                message: "This lifts the block so the title can be requested again.",
                confirmsUnblock: true
            )
        case .chooseSeasons:
            seasonRequestDetails = details
        }
    }

    @ViewBuilder
    private func secondaryActions(_ details: SeerrMediaDetails) -> some View {
        seasonActions(details)
        TrailerButton(trailers: details.trailers)
    }

    /// Beside a show's primary action: request the seasons nobody has
    /// asked for yet, or say only part is here.
    @ViewBuilder
    private func seasonActions(_ details: SeerrMediaDetails) -> some View {
        switch availability {
        case .partiallyAvailable where jellyfinItem != nil:
            if canRequestMoreSeasons(details) {
                requestMoreSeasonsButton(details)
            } else {
                partiallyAvailableStatusButton
            }
        case .available, .pending, .processing:
            if canRequestMoreSeasons(details) {
                requestMoreSeasonsButton(details)
            }
        default:
            EmptyView()
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

    private func canRequestMoreSeasons(_ details: SeerrMediaDetails) -> Bool {
        SeerrMediaDetailModel.canRequestMoreSeasons(
            details,
            mediaType: mediaType,
            user: seerr.user,
            includingSpecials: seerr.publicSettings?.enableSpecialEpisodes == true
        )
    }

    /// A pill beside the primary action.
    private func requestMoreSeasonsButton(_ details: SeerrMediaDetails) -> some View {
        Button {
            seasonRequestDetails = details
        } label: {
            Label("Request More Seasons", systemImage: "plus")
        }
        .accessibilityIdentifier("seerr.detail.request")
        .buttonStyle(.glass)
    }

    private var partiallyAvailableStatusButton: some View {
        let action = SeerrPrimaryAction.partiallyAvailable
        return Button {
            guard case .explain(let message) = action.tap else { return }
            popup = Popup(title: action.title, message: message)
        } label: {
            SeerrStatusLabel(title: action.title, symbol: action.symbol, motion: action.motion)
                .detailPrimaryLabel()
        }
        .detailPrimaryButton()
    }

    private var availability: SeerrAvailabilityStatus {
        model.details?.mediaInfo?.availability ?? .unknown
    }

    private func load(isRefresh: Bool = false) async {
        await model.load(client: seerr.client, jellyfin: session.client, isRefresh: isRefresh)
    }

    private func unblock() {
        isRequesting = true
        Task {
            defer { isRequesting = false }
            do {
                try await seerr.client.removeFromBlocklist(tmdbID: mediaID, mediaType: mediaType)
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
        model.errorMessage = nil
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
        guard let minutes else { return nil }
        return MediaItem.runtimeLabel(minutes: minutes)
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
        page
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

    @ViewBuilder
    private var page: some View {
        #if os(tvOS)
        // A sheet toolbar on tvOS truncates Cancel beside the count.
        TVModalPanel(
            title: Text(details.displayTitle),
            subtitle: "Choose Seasons",
            doneTitle: "Cancel",
            doneIdentifier: "seerr.seasons.cancel"
        ) {
            requestButton
                .buttonStyle(.glass)
                .accessibilityIdentifier("seerr.seasons.submit")
        } content: {
            VStack(spacing: Metrics.Space.m) {
                selectAllButton
                ForEach(visibleSeasons) { seasonButton($0) }
            }
        }
        #else
        ThemedForm {
            Section { selectAllButton }
            Section(details.displayTitle) {
                ForEach(visibleSeasons) { seasonButton($0) }
            }
        }
        .navigationTitle("Choose Seasons")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                requestButton
                    .accessibilityIdentifier("seerr.seasons.submit")
            }
        }
        #endif
    }

    private var requestButton: some View {
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
    }

    private var selectAllButton: some View {
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

    private func seasonButton(_ season: SeerrSeason) -> some View {
        let selectable = isSelectable(season)
        return Button {
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

    private var visibleSeasons: [SeerrSeason] {
        details.requestSeasons(includingSpecials: seerr.publicSettings?.enableSpecialEpisodes == true)
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
        details.canRequestSeason(season.seasonNumber)
    }

    private func seasonState(_ season: SeerrSeason) -> String {
        let status = details.mediaInfo?.seasons?.first { $0.seasonNumber == season.seasonNumber }?.availability
        switch status {
        case .available, .partiallyAvailable: return status?.title ?? ""
        default: return String(localized: "Requested")
        }
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
