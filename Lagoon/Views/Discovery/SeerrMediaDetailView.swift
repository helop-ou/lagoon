import SwiftUI

struct SeerrMediaDetailView: View {
    let mediaID: Int
    let mediaType: SeerrMediaType

    @Environment(SessionStore.self) private var session
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var details: SeerrMediaDetails?
    @State private var jellyfinItem: MediaItem?
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
                    backdropURL: SeerrClient.imageURL(path: details.backdropPath, width: 1280)
                ) {
                    DetailMetadataHeader(
                        subtitle: details.tagline,
                        factTokens: factTokens(details),
                        genres: details.genres?.map(\.name) ?? [],
                        communityRating: displayRating(details.voteAverage),
                        overview: details.overview
                    ) {
                        Text(details.displayTitle)
                            .font(.largeTitle.bold())
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } buttons: {
                        action(details)
                    }
                }
            }
        }
        .task(id: reloadID) { await load() }
        .alert(popup?.title ?? "Seerr", isPresented: Binding(
            get: { popup != nil },
            set: { if !$0 { popup = nil } }
        )) {
            if popup?.confirmsMovieRequest == true {
                Button("Request Movie") {
                    popup = nil
                    requestMovie()
                }
                Button("Cancel", role: .cancel) { popup = nil }
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

    @ViewBuilder
    private func action(_ details: SeerrMediaDetails) -> some View {
        switch availability {
        case .available:
            if let jellyfinItem {
                NavigationLink(value: SeerrNavigationRoute.jellyfinItem(jellyfinItem)) {
                    Label("Open in Lagoon", systemImage: "play.fill")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("seerr.detail.open")
            } else {
                statusButton(
                    title: "Available in Jellyfin",
                    symbol: "checkmark.circle.fill",
                    message: "Seerr reports this title as available, but Lagoon couldn't match it to an item in your current Jellyfin library."
                )
            }
        case .pending, .processing:
            statusButton(
                title: availability.title,
                symbol: "clock",
                message: availability == .pending
                    ? "This request is waiting for approval."
                    : "This title has been approved and is being added to your library."
            )
        case .partiallyAvailable:
            if mediaType == .tv, seerr.user?.canRequest(.tv) == true {
                Button {
                    seasonRequestDetails = details
                } label: {
                    Label("Request More Seasons", systemImage: "plus")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("seerr.detail.request")
            } else {
                statusButton(
                    title: availability.title,
                    symbol: "circle.lefthalf.filled",
                    message: "Some of this title is already available in your Jellyfin library."
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
                        if isRequesting { ProgressView() } else { Label("Request Movie", systemImage: "plus") }
                    }
                    .buttonStyle(.glass)
                    .disabled(isRequesting)
                    .accessibilityIdentifier("seerr.detail.request")
                } else {
                    Button {
                        seasonRequestDetails = details
                    } label: {
                        Label("Choose Seasons", systemImage: "plus")
                    }
                    .buttonStyle(.glass)
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

    private func statusButton(title: String, symbol: String, message: String) -> some View {
        Button {
            popup = Popup(title: title, message: message)
        } label: {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.glass)
    }

    private var availability: SeerrAvailabilityStatus {
        details?.mediaInfo?.availability ?? .unknown
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let loaded = try await seerr.client.details(id: mediaID, mediaType: mediaType)
            guard !Task.isCancelled else { return }
            details = loaded
            if loaded.mediaInfo?.availability == .available {
                jellyfinItem = try? await session.client.item(tmdbID: mediaID, mediaType: mediaType)
            } else {
                jellyfinItem = nil
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
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
    }
}

struct SeerrSeasonRequestView: View {
    let details: SeerrMediaDetails
    @Environment(\.dismiss) private var dismiss
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var selected: Set<Int> = []
    @State private var isRequesting = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Button {
                    selectAllOrClear()
                } label: {
                    Text(allSelectableSeasonsAreSelected ? "Clear Selection" : "Select All Available")
                }
                .buttonStyle(.borderless)
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
                                    Text("\(count) episodes")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            selectionAccessory(for: season, selectable: selectable)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
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
                    submit()
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
