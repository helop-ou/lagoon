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
    @State private var confirmationMessage: String?
    @State private var confirmsMovieRequest = false
    @State private var reloadID = 0

    var body: some View {
        Group {
            if isLoading, details == nil {
                LoadingView()
            } else if let errorMessage, details == nil {
                ErrorStateView(message: errorMessage) { reloadID += 1 }
            } else if let details {
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.Space.section) {
                        hero(details)
                        if let genres = details.genres, !genres.isEmpty {
                            Text(genres.map(\.name).joined(separator: " · "))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Metrics.screenGutter)
                        }
                    }
                    .padding(.bottom, Metrics.Space.section)
                }
                .scrollClipDisabled()
            }
        }
        .navigationTitle(details?.displayTitle ?? mediaType.title)
        .task(id: reloadID) { await load() }
        .confirmationDialog(
            "Request \(details?.displayTitle ?? "this movie")?",
            isPresented: $confirmsMovieRequest,
            titleVisibility: .visible
        ) {
            Button("Request Movie") { requestMovie() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Seerr", isPresented: Binding(
            get: { confirmationMessage != nil },
            set: { if !$0 { confirmationMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(confirmationMessage ?? "")
        }
        .accessibilityIdentifier("seerr.detail.\(mediaType.rawValue).\(mediaID)")
    }

    private func hero(_ details: SeerrMediaDetails) -> some View {
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(
                url: SeerrClient.imageURL(path: details.backdropPath, width: 1280),
                maxPixelSize: 1280
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.04)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.heroHeight)
            .clipped()

            LinearGradient(
                colors: [.black.opacity(0.94), .black.opacity(0.45), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )

            HStack(alignment: .bottom, spacing: Metrics.Space.xxl) {
                CachedAsyncImage(
                    url: SeerrClient.imageURL(path: details.posterPath, width: 500),
                    maxPixelSize: Int(Metrics.posterHeight)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.07)
                }
                .frame(width: Metrics.posterWidth, height: Metrics.posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))

                VStack(alignment: .leading, spacing: Metrics.Space.l) {
                    if let tagline = details.tagline, !tagline.isEmpty {
                        Text(tagline)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    Text(details.displayTitle)
                        .font(.largeTitle.bold())
                        .lineLimit(2)

                    HStack(spacing: Metrics.Space.m) {
                        if let year = details.year { Text(year) }
                        if let runtime = runtimeText(details) { Text(runtime) }
                        if let rating = details.voteAverage, rating > 0 {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        }
                        Text(availability.title)
                    }
                    .font(.footnote)

                    if let overview = details.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .frame(maxWidth: 760, alignment: .leading)
                    }

                    action(details)
                }
                .frame(maxWidth: 900, alignment: .leading)
            }
            .padding(.horizontal, Metrics.screenGutter)
            .padding(.bottom, Metrics.Space.xxl)
        }
        .frame(height: Metrics.heroHeight)
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
                Label("Available in Jellyfin", systemImage: "checkmark.circle.fill")
                    .font(.callout.bold())
            }
        case .pending, .processing:
            Label(availability.title, systemImage: "clock")
                .font(.callout.bold())
        case .partiallyAvailable:
            if mediaType == .tv, seerr.user?.canRequest(.tv) == true {
                NavigationLink(value: SeerrNavigationRoute.seasonRequest(details)) {
                    Label("Request More Seasons", systemImage: "plus")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("seerr.detail.request")
            } else {
                Label(availability.title, systemImage: "circle.lefthalf.filled")
                    .font(.callout.bold())
            }
        case .unknown, .deleted:
            if seerr.user?.canRequest(mediaType) == true {
                if mediaType == .movie {
                    Button {
                        confirmsMovieRequest = true
                    } label: {
                        if isRequesting { ProgressView() } else { Label("Request Movie", systemImage: "plus") }
                    }
                    .buttonStyle(.glass)
                    .disabled(isRequesting)
                    .accessibilityIdentifier("seerr.detail.request")
                } else {
                    NavigationLink(value: SeerrNavigationRoute.seasonRequest(details)) {
                        Label("Choose Seasons", systemImage: "plus")
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("seerr.detail.request")
                }
            } else {
                Text("Your Seerr account cannot request this title.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

        if let errorMessage, self.details != nil {
            Text(errorMessage)
                .font(.callout)
                .foregroundStyle(.red)
        }
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
                confirmationMessage = "Request \(request.requestStatus.title.lowercased())."
                reloadID += 1
            } catch {
                errorMessage = error.localizedDescription
            }
            isRequesting = false
        }
    }

    private func runtimeText(_ details: SeerrMediaDetails) -> String? {
        let minutes = details.runtime ?? details.episodeRunTime?.first
        guard let minutes, minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

struct SeerrSeasonRequestView: View {
    let details: SeerrMediaDetails
    @Environment(\.dismiss) private var dismiss
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var selected: Set<Int> = []
    @State private var isRequesting = false
    @State private var errorMessage: String?
    @State private var confirmsRequest = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
                Text("Choose Seasons")
                    .font(.largeTitle.bold())
                Text(details.displayTitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                HStack(spacing: Metrics.Space.m) {
                    Button(selected.count == selectableSeasons.count ? "Clear" : "Select All") {
                        if selected.count == selectableSeasons.count {
                            selected.removeAll()
                        } else {
                            selected = Set(selectableSeasons.map(\.seasonNumber))
                        }
                    }
                    .buttonStyle(.glass)

                    Button {
                        confirmsRequest = true
                    } label: {
                        if isRequesting {
                            ProgressView()
                        } else {
                            Text("Request \(selected.count) Season\(selected.count == 1 ? "" : "s")")
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(selected.isEmpty || isRequesting)
                    .accessibilityIdentifier("seerr.seasons.submit")
                }

                LazyVGrid(columns: seasonColumns, alignment: .leading, spacing: Metrics.Space.l) {
                    ForEach(visibleSeasons) { season in
                        let selectable = isSelectable(season)
                        Button {
                            if selected.contains(season.seasonNumber) {
                                selected.remove(season.seasonNumber)
                            } else {
                                selected.insert(season.seasonNumber)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                                    Text(season.displayName).font(.headline)
                                    if let count = season.episodeCount {
                                        Text("\(count) episodes").font(.caption)
                                    }
                                }
                                Spacer()
                                if selected.contains(season.seasonNumber) {
                                    Image(systemName: "checkmark")
                                } else if !selectable {
                                    Text(seasonState(season))
                                        .font(.caption)
                                }
                            }
                            .padding(Metrics.Space.l)
                            .frame(maxWidth: .infinity, minHeight: 90)
                        }
                        .buttonStyle(.glass)
                        .disabled(!selectable)
                        .accessibilityIdentifier("seerr.season.\(season.seasonNumber)")
                    }
                }

                if let errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, Metrics.screenGutter)
            .padding(.vertical, Metrics.Space.xxl)
        }
        .scrollClipDisabled()
        .navigationTitle("Request \(details.displayTitle)")
        .confirmationDialog(
            "Request \(selected.count) season\(selected.count == 1 ? "" : "s")?",
            isPresented: $confirmsRequest,
            titleVisibility: .visible
        ) {
            Button("Send Request") { submit() }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityIdentifier("seerr.seasons")
    }

    private var visibleSeasons: [SeerrSeason] {
        (details.seasons ?? []).filter {
            $0.seasonNumber > 0 || seerr.publicSettings?.enableSpecialEpisodes == true
        }
    }

    private var selectableSeasons: [SeerrSeason] { visibleSeasons.filter(isSelectable) }

    private var seasonColumns: [GridItem] {
        [GridItem(.flexible(), spacing: Metrics.Space.l), GridItem(.flexible(), spacing: Metrics.Space.l)]
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
