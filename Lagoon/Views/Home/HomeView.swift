import SwiftUI

struct HomeView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = HomeViewModel()
    @State private var playerItem: PlayerItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.isLoading {
                LoadingView()
            } else if let errorMessage = viewModel.errorMessage {
                ErrorStateView(message: errorMessage) {
                    Task {
                        await viewModel.retry(
                            client: session.client,
                            accountID: session.activeAccount?.id,
                            homeSectionPreferences: savedHomePreferences
                        )
                    }
                }
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HeroSection(items: heroItems)
                            .padding(.top, Metrics.Space.s)
                            .padding(.bottom, Metrics.Space.xl)

                        if isNativeRowEnabled("lagoon.continueWatching") {
                            MediaRail(
                                title: "Continue Watching",
                                items: viewModel.resume,
                                style: .landscape,
                                showsLandscapeMetadata: true,
                                playAction: { playerItem = PlayerItem(media: $0) },
                                onUserDataChange: refreshUserData
                            )
                        }
                        if isNativeRowEnabled("lagoon.nextUp") {
                            MediaRail(
                                title: "Next Up",
                                items: viewModel.nextUp,
                                style: .landscape,
                                showsLandscapeMetadata: true,
                                playAction: { playerItem = PlayerItem(media: $0) },
                                onUserDataChange: refreshUserData
                            )
                        }
                        // Names the title it is drawn from, so the row says
                        // why it exists rather than being one more shelf.
                        curatedRail(HomeCuratedRows.ID.becauseYouWatched)
                        // Things you deliberately starred outrank things the
                        // server happened to ingest, and the rail hides
                        // itself when empty.
                        if isNativeRowEnabled("lagoon.favorites") {
                            MediaRail(
                                title: "Favorites",
                                items: viewModel.favorites,
                                style: .landscape,
                                onUserDataChange: refreshUserData
                            )
                        }

                        // New. What the server has just taken in, before any
                        // of the curated blocks, because "what changed since
                        // last time" outranks "what you might like".
                        if isNativeRowEnabled("lagoon.recentlyAdded") {
                            ForEach(viewModel.latestRails) { rail in
                                MediaRail(
                                    title: rail.title,
                                    items: rail.items,
                                    style: .landscape,
                                    onUserDataChange: refreshUserData
                                )
                            }
                        }

                        // Movies, as one block. Each block closes with its
                        // own genre shelf, which is the browse exit for
                        // someone none of the rows above reached — a native
                        // discovery path that works on every Jellyfin server,
                        // independent of optional plugins (HEL-84).
                        curatedRail(HomeCuratedRows.ID.highlyRated)
                        curatedRail(HomeCuratedRows.ID.inFourK)
                        curatedRail(HomeCuratedRows.ID.genreSpotlight)
                        curatedRail(HomeCuratedRows.ID.decadeSpotlight)
                        if isNativeRowEnabled("lagoon.movieGenres") {
                            GenreRail(
                                title: "Movie Genres",
                                genres: viewModel.movieGenreShelf,
                                includeTypes: [.movie],
                                identifier: "movies"
                            )
                        }

                        // Shows, as one block, closing the same way.
                        curatedRail(HomeCuratedRows.ID.unstartedSeries)
                        curatedRail(HomeCuratedRows.ID.readyToBinge)
                        if isNativeRowEnabled("lagoon.showGenres") {
                            GenreRail(
                                title: "Show Genres",
                                genres: viewModel.showGenreShelf,
                                includeTypes: [.series],
                                identifier: "shows"
                            )
                        }

                        // Anything at all, last: the row that knows least
                        // about you sits furthest from where you started.
                        curatedRail(HomeCuratedRows.ID.surpriseMe)

                        // Whatever the server's Home Screen Sections plugin
                        // adds on top (HEL-47) — nothing at all without it.
                        ForEach(viewModel.pluginRails) { rail in
                            MediaRail(
                                title: rail.title,
                                items: rail.items,
                                style: .landscape,
                                onUserDataChange: refreshUserData
                            )
                        }

                        Color.clear.frame(height: 60)
                    }
                }
                .scrollClipDisabled()
            }
        }
        .task(id: session.activeAccount?.id) {
            await viewModel.load(
                client: session.client,
                accountID: session.activeAccount?.id,
                homeSectionPreferences: savedHomePreferences
            )
        }
        .onAppear {
            Task {
                await viewModel.refreshProgress(client: session.client)
                await viewModel.refreshPluginRails(
                    client: session.client,
                    preferences: savedHomePreferences
                )
            }
        }
        .restoresFocusAfterPlayer(isPresented: playerItem != nil)
        // `refreshProgress` is documented as running on returning from
        // playback, and `onAppear` above was assumed to deliver that. It does
        // not: dismissing a `fullScreenCover` never re-appears the view
        // underneath it, so the one moment Continue Watching is most likely
        // to have changed — you just watched something — was the one moment
        // neither the rail nor the Top Shelf refreshed (HEL-119).
        .fullScreenCover(item: $playerItem, onDismiss: {
            Task { await refreshUserData() }
        }) { item in
            VideoPlayerView(playerItem: item)
                .preferredColorScheme(.dark)
        }
    }

    /// Marking something watched or favourited from a card menu can move it
    /// between Continue Watching, Next Up and Favorites, so all three are
    /// re-fetched rather than guessing which one moved.
    private func refreshUserData() async {
        await viewModel.refreshProgress(client: session.client)
    }

    /// Jellyfin's half of the shared hero: artwork and logo resolve through
    /// the session's client, and the route keeps the item's own identity.
    private var heroItems: [HeroItem<ContentNavigationRoute>] {
        viewModel.heroItems.map { item in
            HeroItem(
                id: item.id,
                title: item.name ?? "",
                overview: item.overview,
                backdropURL: session.client.imageURL(for: item, kind: .backdrop, maxWidth: 1920),
                logoURL: session.client.imageURL(
                    for: item,
                    kind: .logo,
                    maxWidth: Int(Metrics.logoMaxWidth * 2)
                ),
                route: .item(item)
            )
        }
    }

    private var savedHomePreferences: HomeSectionPreferenceValues {
        HomeSectionPreferencesStore.savedValues(accountID: session.activeAccount?.id)
    }

    private func isNativeRowEnabled(_ id: String) -> Bool {
        savedHomePreferences.isNativeEnabled(id)
    }

    /// One curated row, or nothing at all (HEL-120).
    ///
    /// The view model only publishes a rail once it has enough items to look
    /// deliberate, so absence here means "this server had nothing worth a
    /// row" and the block simply closes up. That is what keeps the order
    /// readable on a small library, where several of these will never appear.
    @ViewBuilder
    private func curatedRail(_ id: String) -> some View {
        if isNativeRowEnabled(id), let rail = viewModel.curatedRails[id] {
            MediaRail(
                title: rail.title,
                items: rail.items,
                style: .landscape,
                playAction: { playerItem = PlayerItem(media: $0) },
                onUserDataChange: refreshUserData
            )
        }
    }
}
