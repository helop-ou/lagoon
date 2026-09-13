import SwiftUI
import Observation

@Observable
final class SeriesDetailViewModel {
    var detail: MediaItem?
    var seasons: [MediaItem] = []
    var selectedSeasonId: String?
    var episodes: [MediaItem] = []
    var isLoadingEpisodes = false
    /// The episode Play starts: in progress if there is one, else the next
    /// unwatched. Nil once the show is finished.
    var upNext: MediaItem?

    func load(client: JellyfinClient, seriesId: String) async {
        async let detailTask = client.item(id: seriesId)
        async let seasonsTask = client.seasons(seriesId: seriesId)
        async let upNextTask = client.nextUpEpisode(seriesId: seriesId)
        detail = try? await detailTask
        seasons = (try? await seasonsTask) ?? []
        upNext = try? await upNextTask
        if selectedSeasonId == nil {
            selectedSeasonId = seasons.first?.id
        }
        await loadEpisodes(client: client, seriesId: seriesId)
    }

    func selectSeason(_ seasonId: String, client: JellyfinClient, seriesId: String) async {
        guard seasonId != selectedSeasonId else { return }
        selectedSeasonId = seasonId
        await loadEpisodes(client: client, seriesId: seriesId)
    }

    func refreshEpisodes(client: JellyfinClient, seriesId: String) async {
        await loadEpisodes(client: client, seriesId: seriesId)
    }

    /// After a watched/favourite toggle or a playback session: the show's own
    /// flags, the episode rail, and *which episode is up next* can all have
    /// moved — marking one watched advances it to the following one.
    /// Returns whether every part the action row acts on was re-read: the
    /// show's own flags, the up-next episode, and the episode rail.
    @discardableResult
    func reloadUserData(client: JellyfinClient, seriesId: String) async -> Bool {
        async let detailTask = client.item(id: seriesId)
        async let upNextTask = client.nextUpEpisode(seriesId: seriesId)
        let refreshedDetail = try? await detailTask
        let refreshedUpNext: Result<MediaItem?, Error>
        do {
            refreshedUpNext = .success(try await upNextTask)
        } catch {
            refreshedUpNext = .failure(error)
        }
        if let refreshedDetail { detail = refreshedDetail }
        if case .success(let item) = refreshedUpNext { upNext = item }
        let episodesRefreshed = await loadEpisodes(client: client, seriesId: seriesId)
        guard case .success = refreshedUpNext else { return false }
        return refreshedDetail != nil && episodesRefreshed
    }

    /// Returns whether the visible season's rail was replaced by a fresh read.
    @discardableResult
    private func loadEpisodes(client: JellyfinClient, seriesId: String) async -> Bool {
        guard let selectedSeasonId else { return true }
        isLoadingEpisodes = true
        let loaded = try? await client.episodes(seriesId: seriesId, seasonId: selectedSeasonId)
        // Stale-response guard: a slow season fetch must not clobber a newer pick.
        guard self.selectedSeasonId == selectedSeasonId else { return false }
        // A foreground sync is opportunistic. Preserve the visible rail
        // when the server is asleep rather than turning a full season
        // into an empty one (HEL-135).
        if let loaded { episodes = loaded }
        isLoadingEpisodes = false
        return loaded != nil
    }
}

struct SeriesDetailView: View {
    let item: MediaItem

    @Environment(SessionStore.self) private var session
    @Environment(ServerSyncState.self) private var serverSync
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @State private var viewModel = SeriesDetailViewModel()
    @State private var playerItem: PlayerItem?
    /// The episode the rail last put focus on. Deliberately *not* cleared
    /// when focus leaves the rail: having browsed to E5, moving up to Play
    /// should start E5, not snap back to whatever was up next.
    @State private var highlighted: MediaItem?

    private var displayed: MediaItem { viewModel.detail ?? item }

    /// What the header describes and the buttons act on: the episode you're
    /// looking at, or the one that would play if you haven't looked yet.
    private var subject: MediaItem? { highlighted ?? viewModel.upNext }

    var body: some View {
        DetailPageScaffold(
            backdropURL: session.client.imageURL(for: displayed, kind: .backdrop, maxWidth: Metrics.detailBackdropRequestWidth),
            posterURL: session.client.imageURL(for: displayed, kind: .poster, maxWidth: Metrics.detailPosterRequestWidth)
        ) {
            DetailHeader(item: displayed, upNext: subject) { actions }
            episodesSection
            CastStrip(people: displayed.people ?? [])
        }
        .task(id: item.id) {
            await viewModel.load(client: session.client, seriesId: item.id)
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
            // Watching an episode moves the show on, so this reloads what's
            // up next as well as the rail — once the stop report that moves
            // it has landed (HEL-132).
            Task {
                await session.client.playbackReports.settle()
                await viewModel.reloadUserData(client: session.client, seriesId: item.id)
            }
        })
    }

    /// Play the episode that's up next, then the toggles, then the season
    /// picker. Play leads so it takes first focus — the same reason the movie
    /// page orders it that way.
    @ViewBuilder
    private var actions: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: Metrics.Space.l) {
            AdaptiveActionStack(spacing: Metrics.detailActionSpacing) {
                if let episode = subject {
                    playButton(for: episode)
                }
                actionRow
            }

            seasonChips
        }
        #else
        if usesLeadingColumn {
            // A regular-width iPad window keeps the TV's composition.
            VStack(alignment: .leading, spacing: Metrics.Space.l) {
                AdaptiveActionStack(spacing: Metrics.detailActionSpacing) {
                    if let episode = subject {
                        playButton(for: episode)
                    }
                    actionRow
                    if let episode = subject {
                        DownloadControl(item: episode)
                    }
                }

                seasonChips
            }
        } else if usesLandscapeRow {
            // A landscape phone (HEL-169): toggles, season picker, then Play
            // on one line with the title art along the poster's lower part.
            // A plain row, not the adaptive stack: when the line is tight
            // the title art gives way, rather than the picker dropping under
            // the circles.
            HStack(spacing: Metrics.detailActionSpacing) {
                actionRow
                if let episode = subject {
                    DownloadControl(item: episode)
                }
                seasonChips
                    .fixedSize()
                if let episode = subject {
                    playButton(for: episode)
                }
            }
        } else {
            // A portrait phone (HEL-169): the same block as a film page. One
            // wide Play for the episode the page is about, then the toggles
            // and the season picker as a row beneath it.
            VStack(spacing: Metrics.Space.m) {
                if let episode = subject {
                    playButton(for: episode)
                }
                AdaptiveActionStack(spacing: Metrics.detailActionSpacing) {
                    actionRow
                    if let episode = subject {
                        DownloadControl(item: episode)
                    }
                    seasonChips
                }
            }
        }
        #endif
    }

    #if os(iOS)
    private var usesLeadingColumn: Bool {
        DetailLayout.usesLeadingColumn(horizontalSizeClass)
    }

    private var usesLandscapeRow: Bool {
        DetailLayout.usesLandscapeRow(horizontalSizeClass, verticalSizeClass)
    }

    private var playButtonMaxWidth: CGFloat? {
        if usesLeadingColumn { return nil }
        return usesLandscapeRow ? Metrics.detailLandscapePlayButtonMaxWidth : Metrics.detailPlayButtonMaxWidth
    }
    #endif

    private func playButton(for episode: MediaItem) -> some View {
        Button {
            playerItem = PlayerItem(media: episode)
        } label: {
            #if os(tvOS)
            Label(
                episode.playbackProgress == nil ? "Play" : "Resume",
                systemImage: "play.fill"
            )
            #else
            Label(
                episode.playbackProgress == nil ? "Play" : "Resume",
                systemImage: "play.fill"
            )
            .font(.title3.weight(.semibold))
            // One line always: a Label squeezed for width stacks its icon
            // over its text, which folded the landscape row's pill into a
            // column once four circles shared the line.
            .fixedSize()
            .frame(maxWidth: playButtonMaxWidth)
            .padding(.vertical, Metrics.Space.xs)
            #endif
        }
        .buttonStyle(.glass)
        #if os(iOS)
        .controlSize(.extraLarge)
        .accessibilityIdentifier("detail.play")
        #endif
    }

    /// The checkmark acts on that episode; the star favourites the show.
    /// Each control targets what it plausibly means next to a Play button
    /// that starts one specific episode.
    private var actionRow: some View {
        ItemActionRow(item: displayed, playedItem: subject) {
            let refreshed = await viewModel.reloadUserData(client: session.client, seriesId: item.id)
            // A hand-picked episode lives in this view's state, which no
            // reload touches: re-match it from the refreshed rail so its
            // watched flag is the server's, not the pick's.
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
                        Task { await viewModel.selectSeason(id, client: session.client, seriesId: item.id) }
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
                                Task { await viewModel.selectSeason(season.id, client: session.client, seriesId: item.id) }
                            }
                            .buttonStyle(.glass)
                            // Weight alone marks the selected season: a colored
                            // label fought the focused lozenge, and `.primary`
                            // under this screen's dark scheme is white — so the
                            // selected chip went invisible when focused (HEL-50).
                            .font(.callout.weight(season.id == viewModel.selectedSeasonId ? .bold : .regular))
                        }
                    }
                    // Focused glass chips scale past their bounds, and a
                    // ScrollView clips at its own edges: the gutter has to live
                    // *inside* the scroll content so the first chip has room to
                    // grow into, exactly as the episode rail below does. Without
                    // the escape below, the scroll view starts at the gutter and
                    // slices the focused chip's leading end flat.
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

            // Stays mounted across season switches — swapping it for a spinner
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
                .padding(.horizontal, Metrics.screenGutter)
                .padding(.top, Metrics.railTopPadding)
                .padding(.bottom, Metrics.railBottomPadding)
            }
            .opacity(viewModel.isLoadingEpisodes ? 0.4 : 1)
            .animation(.easeInOut(duration: Motion.fast), value: viewModel.isLoadingEpisodes)
        }
    }
}

struct EpisodeCard: View {
    let episode: MediaItem
    /// Fires as focus arrives, so the series header can describe whatever
    /// episode you're looking at (HEL-46).
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

    private var episodeAccessibilityLabel: String {
        let base = [episode.episodeLabel, episode.name].compactMap { $0 }.joined(separator: " · ")
        #if os(iOS)
        if DownloadStore.shared.isDownloaded(episode.id) {
            return base + ", downloaded"
        }
        #endif
        return base
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
            #if os(iOS)
            .overlay(alignment: .topTrailing) {
                if DownloadStore.shared.isDownloaded(episode.id) {
                    DownloadedMark()
                        .padding(Metrics.Space.xs)
                }
            }
            #endif
    }
}
