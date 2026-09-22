import SwiftUI
import Observation

@Observable
final class SeriesDetailViewModel {
    var detail: MediaItem?
    var seasons: [MediaItem] = []
    var selectedSeasonId: String?
    var episodes: [MediaItem] = []
    var isLoadingEpisodes = false
    private var loadGeneration = 0
    private var episodeGeneration = 0
    private var loadedSeriesID: String?
    private var loadedIdentity: JellyfinClient.SessionIdentity?
    /// The episode Play starts: in progress if there is one, else the next
    /// unwatched. Nil once the show is finished.
    var upNext: MediaItem?

    /// Play's fallback once the show is finished, so the page always has a
    /// Play button. Follows the season picker.
    var firstEpisode: MediaItem? { episodes.first }

    func load(client: JellyfinClient, seriesId: String) async {
        guard !Task.isCancelled else { return }
        loadGeneration &+= 1
        episodeGeneration &+= 1
        isLoadingEpisodes = false
        let generation = loadGeneration
        let identity = client.sessionIdentity
        if loadedSeriesID != seriesId || loadedIdentity != identity {
            detail = nil
            seasons = []
            episodes = []
            upNext = nil
            selectedSeasonId = nil
        }
        loadedSeriesID = seriesId
        loadedIdentity = identity
        async let detailTask = client.item(id: seriesId)
        async let seasonsTask = client.seasons(seriesId: seriesId)
        async let upNextTask = client.nextUpEpisode(seriesId: seriesId)
        let resolvedDetail = try? await detailTask
        let resolvedSeasons = (try? await seasonsTask) ?? []
        let resolvedUpNext = try? await upNextTask
        guard generation == loadGeneration, identity == client.sessionIdentity, !Task.isCancelled else { return }
        detail = resolvedDetail
        seasons = resolvedSeasons
        upNext = resolvedUpNext
        if selectedSeasonId == nil {
            selectedSeasonId = openingSeasonId
        }
        await loadEpisodes(client: client, seriesId: seriesId)
    }

    /// The up-next episode's season. A finished show opens on its first
    /// regular season, skipping Specials, which the server sorts first.
    private var openingSeasonId: String? {
        if let seasonId = upNextSeasonId { return seasonId }
        return (seasons.first { ($0.indexNumber ?? 0) > 0 } ?? seasons.first)?.id
    }

    /// The up-next episode's season, when it's one the page can show.
    private var upNextSeasonId: String? {
        guard let seasonId = upNext?.seasonId, seasons.contains(where: { $0.id == seasonId }) else { return nil }
        return seasonId
    }

    /// After playback, move the rail to the season now up next; a session
    /// can end seasons away from where it started.
    func followUpNext(client: JellyfinClient, seriesId: String) async {
        guard let seasonId = upNextSeasonId else { return }
        await selectSeason(seasonId, client: client, seriesId: seriesId)
    }

    func selectSeason(_ seasonId: String, client: JellyfinClient, seriesId: String) async {
        guard seasonId != selectedSeasonId else { return }
        selectedSeasonId = seasonId
        await loadEpisodes(client: client, seriesId: seriesId)
    }

    func refreshEpisodes(client: JellyfinClient, seriesId: String) async {
        await loadEpisodes(client: client, seriesId: seriesId)
    }

    /// Re-reads the show's flags, the up-next episode and the rail, which a
    /// toggle or playback can all move. Returns whether all three were re-read.
    @discardableResult
    func reloadUserData(client: JellyfinClient, seriesId: String) async -> Bool {
        let generation = loadGeneration
        let identity = client.sessionIdentity
        guard loadedSeriesID == seriesId, loadedIdentity == identity, !Task.isCancelled else { return false }
        async let detailTask = client.item(id: seriesId)
        async let upNextTask = client.nextUpEpisode(seriesId: seriesId)
        let refreshedDetail = try? await detailTask
        let refreshedUpNext: Result<MediaItem?, Error>
        do {
            refreshedUpNext = .success(try await upNextTask)
        } catch {
            refreshedUpNext = .failure(error)
        }
        guard generation == loadGeneration, identity == client.sessionIdentity, !Task.isCancelled else { return false }
        if let refreshedDetail { detail = refreshedDetail }
        if case .success(let item) = refreshedUpNext { upNext = item }
        let episodesRefreshed = await loadEpisodes(client: client, seriesId: seriesId)
        guard case .success = refreshedUpNext else { return false }
        return refreshedDetail != nil && episodesRefreshed
    }

    /// Returns whether the visible season's rail was replaced by a fresh read.
    @discardableResult
    private func loadEpisodes(client: JellyfinClient, seriesId: String) async -> Bool {
        guard loadedSeriesID == seriesId, loadedIdentity == client.sessionIdentity,
              !Task.isCancelled else { return false }
        guard let selectedSeasonId else { return true }
        let identity = client.sessionIdentity
        episodeGeneration &+= 1
        let generation = episodeGeneration
        isLoadingEpisodes = true
        defer {
            if generation == episodeGeneration { isLoadingEpisodes = false }
        }
        let loaded = try? await client.episodes(seriesId: seriesId, seasonId: selectedSeasonId)
        // An A → B → A selection must reject the first A response too.
        guard generation == episodeGeneration, identity == client.sessionIdentity,
              self.selectedSeasonId == selectedSeasonId, !Task.isCancelled else { return false }
        // Keep the visible rail when the server fails to answer.
        if let loaded { episodes = loaded }
        return loaded != nil
    }
}

struct SeriesDetailView: View {
    let item: MediaItem

    @Environment(SessionStore.self) private var session
    @Environment(ServerSyncState.self) private var serverSync
    @Environment(SyncPlayStore.self) private var syncPlay
    @State private var viewModel = SeriesDetailViewModel()
    @State private var playerItem: PlayerItem?
    /// The episode the rail last focused. Not cleared when focus leaves the
    /// rail, so moving up to Play starts the browsed episode.
    @State private var highlighted: MediaItem?
    /// Set only when the rail's content changes (load, season pick, end of
    /// playback). Setting it while browsing would yank the row under focus.
    @State private var railPosition: String?

    private var displayed: MediaItem { viewModel.detail ?? item }

    /// What the header describes and the buttons act on.
    private var subject: MediaItem? { highlighted ?? viewModel.upNext ?? viewModel.firstEpisode }

    var body: some View {
        DetailPageScaffold(
            backdropURL: session.client.imageURL(for: displayed, kind: .backdrop, maxWidth: Metrics.detailBackdropRequestWidth),
            posterURL: session.client.imageURL(for: displayed, kind: .poster, maxWidth: Metrics.detailPosterRequestWidth)
        ) {
            DetailHeader(item: displayed, upNext: subject, reservesOverviewLines: true) { actions }
            episodesSection
            CastStrip(people: displayed.people ?? [])
        }
        .task(id: item.id) {
            await viewModel.load(client: session.client, seriesId: item.id)
            railPosition = subject?.id
            #if os(iOS)
            await DownloadStore.shared.refreshPermission(client: session.client)
            #endif
            // The Watch Together control renders nothing until this answers,
            // so it cannot run the task itself.
            await syncPlay.refreshAvailability()
        }
        .onChange(of: serverSync.generation) { _, _ in
            Task {
                await viewModel.reloadUserData(client: session.client, seriesId: item.id)
            }
        }
        // The highlight belongs to the season it came from.
        .onChange(of: viewModel.selectedSeasonId) { _, _ in highlighted = nil }
        .restoresFocusAfterPlayer(isPresented: playerItem != nil)
        .playerPresentation(item: $playerItem, onDismiss: {
            // Reload up next once the stop report has landed.
            Task {
                await session.client.playbackReports.settle()
                await viewModel.reloadUserData(client: session.client, seriesId: item.id)
                // Follow where the session ended, not the card picked before it.
                highlighted = nil
                await viewModel.followUpNext(client: session.client, seriesId: item.id)
                railPosition = subject?.id
            }
        })
    }

    /// A picked season's rail starts at its first episode.
    private func showSeason(_ seasonId: String) async {
        guard seasonId != viewModel.selectedSeasonId else { return }
        await viewModel.selectSeason(seasonId, client: session.client, seriesId: item.id)
        railPosition = viewModel.firstEpisode?.id
    }

    /// Play leads so it takes first focus.
    private var actions: some View {
        DetailActionLayout {
            if let episode = subject {
                playButton(for: episode)
            }
        } secondary: {
            actionRow
            #if os(iOS)
            if let episode = subject {
                DownloadControl(item: episode)
            }
            #endif
            if let episode = subject {
                WatchTogetherControl(
                    item: episode,
                    startPositionTicks: episode.userData?.playbackPositionTicks ?? 0
                )
            }
        } accessory: {
            seasonChips
        }
    }

    private func playButton(for episode: MediaItem) -> some View {
        Button {
            playerItem = PlayerItem(media: episode)
        } label: {
            Label(
                episode.playbackProgress == nil ? "Play" : "Resume",
                systemImage: "play.fill"
            )
            .detailPrimaryLabel()
        }
        .detailPrimaryButton()
        #if os(iOS)
        .accessibilityIdentifier("detail.play")
        #endif
    }

    /// The checkmark acts on the show itself once every episode is watched,
    /// so it clears the whole show rather than episode one.
    private var actionRow: some View {
        ItemActionRow(item: displayed, playedItem: highlighted ?? viewModel.upNext) {
            let refreshed = await viewModel.reloadUserData(client: session.client, seriesId: item.id)
            // Reloads never touch this view's state: re-match the picked
            // episode so its watched flag is the server's.
            if let picked = highlighted {
                guard let fresh = viewModel.episodes.first(where: { $0.id == picked.id }) else { return false }
                highlighted = fresh
            }
            return refreshed
        }
    }

    @ViewBuilder
    private var seasonChips: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            if !viewModel.seasons.isEmpty {
                #if os(iOS)
                Picker("Season", selection: Binding(
                    get: { viewModel.selectedSeasonId },
                    set: { id in
                        guard let id else { return }
                        Task { await showSeason(id) }
                    }
                )) {
                    ForEach(viewModel.seasons) { season in
                        Text(season.name ?? "Season").tag(Optional(season.id))
                    }
                }
                .pickerStyle(.menu)
                .buttonStyle(.glass)
                .accessibilityIdentifier("series.season")
                #else
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Metrics.Space.m) {
                        ForEach(viewModel.seasons) { season in
                            Button(season.name ?? "Season") {
                                Task { await showSeason(season.id) }
                            }
                            .buttonStyle(.glass)
                            // Weight alone marks the selection: a label color
                            // turns invisible on the focused chip.
                            .font(.callout.weight(season.id == viewModel.selectedSeasonId ? .bold : .regular))
                        }
                    }
                    // The gutter lives inside the scroll content, with the
                    // negative padding below, so a focused chip's lift is not
                    // clipped at the scroll view's edge.
                    .padding(.horizontal, Metrics.screenGutter)
                    .padding(.vertical, Metrics.Space.l)
                }
                .padding(.horizontal, -Metrics.screenGutter)
                #endif
            }
        }
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Episodes")
                .font(.title3.bold())
                .padding(.leading, Metrics.screenGutter)

            // Stays mounted across season switches; a spinner in its place
            // collapses the layout and makes focus jump.
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Metrics.cardSpacing) {
                    ForEach(viewModel.episodes) { episode in
                        EpisodeCard(episode: episode) {
                            highlighted = episode
                        } action: {
                            playerItem = PlayerItem(media: episode)
                        }
                        .itemUserDataMenu(item: episode) {
                            await viewModel.reloadUserData(client: session.client, seriesId: item.id)
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.top, Metrics.railTopPadding)
                .padding(.bottom, Metrics.railBottomPadding)
            }
            // A content margin, not padding: scrolling lands an episode at
            // the gutter, and the full-width viewport keeps focus lift unclipped.
            .contentMargins(.horizontal, Metrics.screenGutter, for: .scrollContent)
            .scrollPosition(id: $railPosition, anchor: .leading)
            .opacity(viewModel.isLoadingEpisodes ? 0.4 : 1)
            .animation(.easeInOut(duration: Motion.fast), value: viewModel.isLoadingEpisodes)
        }
    }
}

struct EpisodeCard: View {
    let episode: MediaItem
    /// Fires on focus so the series header can describe this episode.
    var onFocus: (() -> Void)?
    let action: () -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.displayScale) private var displayScale
    @FocusState private var isFocused: Bool

    private var cardWidth: CGFloat { Metrics.landscapeWidth * 0.89 }
    private var cardHeight: CGFloat { (cardWidth * 9 / 16).rounded() }

    var body: some View {
        Group {
            #if os(iOS)
            NavigationLink(value: ContentNavigationRoute.item(episode)) { artwork }
            #else
            Button(action: action) { artwork }
            #endif
        }
        .focused($isFocused)
        .cardButtonStyle()
        .accessibilityLabel(episodeAccessibilityLabel)
        .onChange(of: isFocused) { _, focused in
            if focused { onFocus?() }
        }
    }

    private var isWatched: Bool { episode.userData?.played == true }

    private var episodeAccessibilityLabel: String {
        var parts = [[episode.episodeLabel, episode.name].compactMap { $0 }.joined(separator: " · ")]
        if isWatched {
            parts.append(String(localized: "watched"))
        }
        #if os(iOS)
        if DownloadStore.shared.isDownloaded(episode.id) {
            parts.append(String(localized: "downloaded"))
        }
        #endif
        return parts.joined(separator: ", ")
    }

    private var artwork: some View {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(
                    url: session.client.imageURL(for: episode, kind: .thumb, maxWidth: ArtworkSizing.pixels(for: cardWidth, displayScale: displayScale)),
                    maxPixelSize: ArtworkSizing.pixels(for: cardWidth, displayScale: displayScale)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipped()

                LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .bottom, endPoint: .top)
                    .frame(height: cardHeight * 0.55)
                    .frame(maxWidth: .infinity, alignment: .bottom)

                VStack(alignment: .leading, spacing: Metrics.Space.hair) {
                    if let label = episode.episodeLabel {
                        Text(label)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(episode.name ?? "")
                        .font(.footnote.bold())
                        .lineLimit(1)
                }
                .padding(.horizontal, Metrics.Space.m)
                .padding(.bottom, episode.playbackProgress == nil ? 10 : 20)

                if let progress = episode.playbackProgress {
                    ItemProgressBar(progress: progress)
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
            .overlay(alignment: .topTrailing) {
                HStack(spacing: Metrics.Space.xs) {
                    if isWatched {
                        WatchedMark()
                    }
                    #if os(iOS)
                    if DownloadStore.shared.isDownloaded(episode.id) {
                        DownloadedMark()
                    }
                    #endif
                }
                .padding(Metrics.cardMarkInset)
            }
    }
}
