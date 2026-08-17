import SwiftUI
import Observation

@Observable
final class SeriesDetailViewModel {
    var detail: MediaItem?
    var seasons: [MediaItem] = []
    var selectedSeasonId: String?
    var episodes: [MediaItem] = []
    var isLoadingEpisodes = false

    func load(client: JellyfinClient, seriesId: String) async {
        async let detailTask = client.item(id: seriesId)
        async let seasonsTask = client.seasons(seriesId: seriesId)
        detail = try? await detailTask
        seasons = (try? await seasonsTask) ?? []
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

    /// After a watched/favourite toggle on the series itself — marking a
    /// series played marks every episode, so the rail has to reload too.
    func reloadUserData(client: JellyfinClient, seriesId: String) async {
        detail = try? await client.item(id: seriesId)
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

    private var displayed: MediaItem { viewModel.detail ?? item }

    var body: some View {
        DetailPageScaffold(
            backdropURL: session.client.imageURL(for: displayed, kind: .backdrop, maxWidth: 1920)
        ) {
            DetailHeader(item: displayed) { seasonChips }
            episodesSection
            CastStrip(people: displayed.people ?? [])
        }
        .task(id: item.id) {
            await viewModel.load(client: session.client, seriesId: item.id)
        }
        .restoresFocusAfterPlayer(isPresented: playerItem != nil)
        .fullScreenCover(item: $playerItem, onDismiss: {
            Task { await viewModel.refreshEpisodes(client: session.client, seriesId: item.id) }
        }) { player in
            VideoPlayerView(playerItem: player)
                .preferredColorScheme(.dark)
        }
    }

    /// Season picker with the watched/favourite toggles alongside it. The
    /// chips come **first** so focus lands on a season when the page opens:
    /// with the toggles leading, arriving and pressing Select would have
    /// marked the whole series — every episode — watched.
    @ViewBuilder
    private var seasonChips: some View {
        // Stacked rather than one row: a horizontal ScrollView is greedy, so
        // sharing a row would pin the toggles to the far edge of a 16:9
        // screen, a long way from the chips they sit with. There's no Play
        // button here to pair them with either.
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.seasons.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
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
                    .padding(.vertical, 16)
                }
                .padding(.horizontal, -Metrics.screenGutter)
            }

            // Marking a series watched marks every episode — the same toggle,
            // one level up.
            ItemActionRow(item: displayed) {
                await viewModel.reloadUserData(client: session.client, seriesId: item.id)
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
    let action: () -> Void
    @Environment(SessionStore.self) private var session

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

                VStack(alignment: .leading, spacing: 3) {
                    if let label = episode.episodeLabel {
                        Text(label)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(episode.name ?? "")
                        .font(.footnote.bold())
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, episode.playbackProgress == nil ? 10 : 20)

                if let progress = episode.playbackProgress {
                    ItemProgressBar(progress: progress)
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
        }
        .cardButtonStyle()
        .accessibilityLabel(episode.name ?? "Episode")
    }
}
