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
    func reloadUserData(client: JellyfinClient, seriesId: String) async {
        async let detailTask = client.item(id: seriesId)
        async let upNextTask = client.nextUpEpisode(seriesId: seriesId)
        detail = try? await detailTask
        upNext = try? await upNextTask
        await loadEpisodes(client: client, seriesId: seriesId)
    }

    private func loadEpisodes(client: JellyfinClient, seriesId: String) async {
        guard let selectedSeasonId else { return }
        isLoadingEpisodes = true
        let loaded = (try? await client.episodes(seriesId: seriesId, seasonId: selectedSeasonId)) ?? []
        // Stale-response guard: a slow season fetch must not clobber a newer pick.
        if self.selectedSeasonId == selectedSeasonId {
            episodes = loaded
            isLoadingEpisodes = false
        }
    }
}

struct SeriesDetailView: View {
    let item: MediaItem

    @Environment(SessionStore.self) private var session
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
            backdropURL: session.client.imageURL(for: displayed, kind: .backdrop, maxWidth: 1920)
        ) {
            DetailHeader(item: displayed, upNext: subject) { actions }
            episodesSection
            CastStrip(people: displayed.people ?? [])
        }
        .task(id: item.id) {
            await viewModel.load(client: session.client, seriesId: item.id)
        }
        // The highlight belongs to the season it came from.
        .onChange(of: viewModel.selectedSeasonId) { _, _ in highlighted = nil }
        .restoresFocusAfterPlayer(isPresented: playerItem != nil)
        .fullScreenCover(item: $playerItem, onDismiss: {
            // Watching an episode moves the show on, so this reloads what's
            // up next as well as the rail.
            Task { await viewModel.reloadUserData(client: session.client, seriesId: item.id) }
        }) { player in
            VideoPlayerView(playerItem: player)
                .preferredColorScheme(.dark)
        }
    }

    /// Play the episode that's up next, then the toggles, then the season
    /// picker. Play leads so it takes first focus — the same reason the movie
    /// page orders it that way.
    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.l) {
            HStack(spacing: Metrics.Space.l) {
                if let episode = subject {
                    Button {
                        playerItem = PlayerItem(media: episode)
                    } label: {
                        Label(
                            episode.playbackProgress == nil ? "Play" : "Resume",
                            systemImage: "play.fill"
                        )
                    }
                    .buttonStyle(.glass)
                }

                // The checkmark acts on that episode; the star favourites the
                // show. Each control targets what it plausibly means next to
                // a Play button that starts one specific episode.
                ItemActionRow(item: displayed, playedItem: subject) {
                    await viewModel.reloadUserData(client: session.client, seriesId: item.id)
                }
            }

            seasonChips
        }
    }

    @ViewBuilder
    private var seasonChips: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            if !viewModel.seasons.isEmpty {
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
    @FocusState private var isFocused: Bool

    private var cardWidth: CGFloat { Metrics.landscapeWidth * 0.89 }
    private var cardHeight: CGFloat { (cardWidth * 9 / 16).rounded() }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(
                    url: session.client.imageURL(for: episode, kind: .thumb, maxWidth: Int(cardWidth * 1.5)),
                    maxPixelSize: Int(cardWidth * 1.5)
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
        }
        .focused($isFocused)
        .cardButtonStyle()
        .accessibilityLabel(episode.name ?? "Episode")
        .onChange(of: isFocused) { _, focused in
            if focused { onFocus?() }
        }
    }
}
