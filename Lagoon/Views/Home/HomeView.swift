import SwiftUI

struct HomeView: View {
    @Environment(SessionStore.self) private var session
    @Environment(ServerSyncState.self) private var serverSync
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

                        // Movies, uninterrupted, ending with the genre shelf
                        // as the browse exit for anyone none of the rows
                        // reached — a native discovery path that works on
                        // every Jellyfin server, independent of optional
                        // plugins (HEL-84).
                        //
                        // Recently Added sits inside its own block rather
                        // than in a "new" block of its own, which is what
                        // Discover does and what keeps a run of movies from
                        // being split by a row of television.
                        recentlyAddedRails(collectionType: "movies")
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

                        // Shows, uninterrupted, closing the same way.
                        recentlyAddedRails(collectionType: "tvshows")
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

                        // Any library that is neither, so a server with a
                        // third kind of collection does not lose its rail.
                        recentlyAddedRails(collectionType: nil)

                        // The last browse shelf, and the only one that spans
                        // both blocks: a collection is a franchise, which is
                        // usually films but is not promised to be (HEL-122).
                        // It sits with the genre shelves in spirit — a way
                        // out into the library rather than something picked
                        // for you — so it closes the browse exits before the
                        // final content row.
                        if isNativeRowEnabled(CollectionShelf.rowID) {
                            CollectionRail(
                                title: "Collections",
                                collections: viewModel.collections
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
        .onChange(of: serverSync.generation) { _, _ in
            Task {
                await viewModel.refreshServerContent(
                    client: session.client,
                    homeSectionPreferences: savedHomePreferences
                )
            }
        }
        .restoresFocusAfterPlayer(isPresented: playerItem != nil)
        // `refreshProgress` is documented as running on returning from
        // playback, and `onAppear` above was assumed to deliver that. It does
        // not: dismissing a `fullScreenCover` never re-appears the view
        // underneath it, so the one moment Continue Watching is most likely
        // to have changed — you just watched something — was the one moment
        // neither the rail nor the Top Shelf refreshed (HEL-119). The stop
        // report is still in flight when this fires; `settle()` waits for
        // it so the rails read the new position, not the old (HEL-132).
        .fullScreenCover(item: $playerItem, onDismiss: {
            Task {
                await session.client.playbackReports.settle()
                await refreshUserData()
            }
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

    /// The Recently Added rails belonging to one kind of library, so each one
    /// lands inside its own block rather than in a run of its own.
    ///
    /// A nil `collectionType` collects whatever is neither movies nor shows.
    /// `load` only keeps those two today, so it draws nothing — but a rail
    /// silently vanishing is a worse way to find that out than a rail
    /// appearing in an odd place.
    @ViewBuilder
    private func recentlyAddedRails(collectionType: String?) -> some View {
        if isNativeRowEnabled("lagoon.recentlyAdded") {
            let rails = viewModel.latestRails.filter {
                collectionType == nil
                    ? !["movies", "tvshows"].contains($0.collectionType ?? "")
                    : $0.collectionType == collectionType
            }
            ForEach(rails) { rail in
                MediaRail(
                    title: rail.title,
                    items: rail.items,
                    style: .landscape,
                    onUserDataChange: refreshUserData
                )
            }
        }
    }

    /// One curated row, or nothing at all (HEL-120).
    ///
    /// The view model only publishes a rail once it has enough items to look
    /// deliberate, so absence here means "this server had nothing worth a
    /// row" and the block simply closes up. That is what keeps the order
    /// readable on a small library, where several of these will never appear.
    ///
    /// **No `playAction`.** These are discovery rails, and every one of them
    /// selects into the item's detail page. Handing them the resume rails'
    /// play action — which is how they first shipped — was wrong twice over:
    /// a movie you have never seen started playing instead of telling you
    /// what it was, and a series has no stream at all, so "Series You
    /// Haven't Started" answered the click with the server's 500 from
    /// PlaybackInfo on a folder.
    @ViewBuilder
    private func curatedRail(_ id: String) -> some View {
        if isNativeRowEnabled(id), let rail = viewModel.curatedRails[id] {
            MediaRail(
                title: rail.title,
                items: rail.items,
                style: .landscape,
                onUserDataChange: refreshUserData
            )
        }
    }
}
