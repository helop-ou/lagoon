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

    /// The episode Play starts when nothing is up next: the first of the
    /// visible season. A finished show has no next episode, and a page with
    /// no Play button read as broken rather than as "you've seen it all"
    /// (HEL-175). Starting the season over is the one obvious thing to
    /// offer, and it moves with the season picker.
    var firstEpisode: MediaItem? { episodes.first }

    func load(client: JellyfinClient, seriesId: String) async {
        async let detailTask = client.item(id: seriesId)
        async let seasonsTask = client.seasons(seriesId: seriesId)
        async let upNextTask = client.nextUpEpisode(seriesId: seriesId)
        detail = try? await detailTask
        seasons = (try? await seasonsTask) ?? []
        upNext = try? await upNextTask
        if selectedSeasonId == nil {
            selectedSeasonId = openingSeasonId
        }
        await loadEpisodes(client: client, seriesId: seriesId)
    }

    /// Where the page opens: the season holding the episode that's up next,
    /// so the rail shows what surrounds it rather than season one every
    /// time. A finished show opens on its first regular season; the server
    /// sorts Specials first, and they are the wrong place to start a rewatch.
    private var openingSeasonId: String? {
        if let seasonId = upNextSeasonId { return seasonId }
        return (seasons.first { ($0.indexNumber ?? 0) > 0 } ?? seasons.first)?.id
    }

    /// The up-next episode's season, when it's one the page can show.
    private var upNextSeasonId: String? {
        guard let seasonId = upNext?.seasonId, seasons.contains(where: { $0.id == seasonId }) else { return nil }
        return seasonId
    }

    /// After playback: a session can end seasons away from where it started,
    /// so the rail follows the episode that is now up next (HEL-175). Nothing
    /// changes when it is already in view, or the show is finished.
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
    @Environment(SyncPlayStore.self) private var syncPlay
    @State private var viewModel = SeriesDetailViewModel()
    @State private var playerItem: PlayerItem?
    /// The episode the rail last put focus on. Deliberately *not* cleared
    /// when focus leaves the rail: having browsed to E5, moving up to Play
    /// should start E5, not snap back to whatever was up next.
    @State private var highlighted: MediaItem?
    /// The episode at the rail's leading edge. The page sets it when the
    /// rail's content changes hands (a load, a season pick, a finished
    /// playback session) so the episode Play names is in view; browsing the
    /// rail leaves it to the scroll view, which would otherwise yank the row
    /// under a moving focus (HEL-175).
    @State private var railPosition: String?

    private var displayed: MediaItem { viewModel.detail ?? item }

    /// What the header describes and the buttons act on: the episode you're
    /// looking at, the one that would play if you haven't looked yet, or the
    /// first of the visible season once the show is finished.
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
            // The Watch Together control renders nothing until the server
            // has answered, and a task on a view that renders nothing never
            // runs, so the page asks (HEL-172).
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
            // Watching an episode moves the show on, so this reloads what's
            // up next as well as the rail — once the stop report that moves
            // it has landed (HEL-132).
            Task {
                await session.client.playbackReports.settle()
                await viewModel.reloadUserData(client: session.client, seriesId: item.id)
                // The page is about wherever the session ended, not the
                // card picked before it: a binge from S1 E1 can stop in
                // S3, and the server's answer for what's up next is the
                // only one that knows (HEL-175).
                highlighted = nil
                await viewModel.followUpNext(client: session.client, seriesId: item.id)
                railPosition = subject?.id
            }
        })
    }

    /// A season the viewer picked: its rail starts at the beginning. Picking
    /// the season already showing leaves the rail where it is.
    private func showSeason(_ seasonId: String) async {
        guard seasonId != viewModel.selectedSeasonId else { return }
        await viewModel.selectSeason(seasonId, client: session.client, seriesId: item.id)
        railPosition = viewModel.firstEpisode?.id
    }

    /// Play the episode that's up next, then the toggles, then the season
    /// picker. Play leads so it takes first focus — the same reason the movie
    /// page orders it that way. The season picker is the layout's accessory:
    /// in the row with the circles on a phone, under the row where there is
    /// width (HEL-169).
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
            // A group started from a show is a group watching the episode
            // Play would start, from where that episode was left — the same
            // subject every other control on this row acts on (HEL-172).
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

    /// The checkmark acts on the episode you're looking at or the one up
    /// next, and on the show itself once every episode is watched, where
    /// Play offers a rewatch from episode one but the check should clear
    /// the whole show, not just that episode. The star favourites the show.
    private var actionRow: some View {
        ItemActionRow(item: displayed, playedItem: highlighted ?? viewModel.upNext) {
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
                .scrollTargetLayout()
                .padding(.top, Metrics.railTopPadding)
                .padding(.bottom, Metrics.railBottomPadding)
            }
            // The gutter is a content margin rather than padding so that
            // scrolling to an episode lands it at the gutter, not flush with
            // the screen edge; the viewport still spans the whole width, so
            // a focused card's lift is not clipped at the edge.
            .contentMargins(.horizontal, Metrics.screenGutter, for: .scrollContent)
            .scrollPosition(id: $railPosition, anchor: .leading)
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
