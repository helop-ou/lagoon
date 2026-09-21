import SwiftUI

struct HomeView: View {
    let isActive: Bool
    let heroFocus: FocusState<Bool>.Binding
    @Environment(SessionStore.self) private var session
    @State private var viewModel = HomeViewModel()
    @State private var playerItem: PlayerItem?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if viewModel.isLoading {
                LoadingView()
            } else if let errorMessage = viewModel.errorMessage {
                ErrorStateView(message: errorMessage) {
                    Task {
                        await viewModel.retry(
                            client: session.client,
                            accountID: session.activeAccount?.id,
                            homeSectionPreferences: savedHomePreferences,
                            seerr: session.seerr.client
                        )
                    }
                }
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HeroSection(
                            items: heroItems,
                            isActive: isActive && playerItem == nil,
                            focus: heroFocus
                        )
                            .padding(.top, Metrics.Space.s)
                            .padding(.bottom, Metrics.Space.xl)

                        // A group whose player has been closed, above the
                        // rails and below the hero: the one thing on Home
                        // that is about right now rather than about the
                        // library. It draws nothing otherwise.
                        WatchTogetherHomeCard()

                        // The order is the viewer's, or Lagoon's default when
                        // they have not arranged one. Neither lives
                        // here: see `HomeSectionPreferenceResolver`, which
                        // owns the default order, the arrangement that
                        // replaces it, and which rows either one hides.
                        ForEach(rowOrder, id: \.self) { id in
                            row(id)
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
                homeSectionPreferences: savedHomePreferences,
                seerr: session.seerr.client
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
        .serverRefreshable(.home, isActive: isActive, isPaused: playerItem != nil) {
            await viewModel.refreshServerContent(
                client: session.client,
                homeSectionPreferences: savedHomePreferences,
                seerr: session.seerr.client
            )
        }
        .restoresFocusAfterPlayer(isPresented: playerItem != nil)
        // `refreshProgress` is documented as running on returning from
        // playback, and `onAppear` above was assumed to deliver that. It does
        // not: dismissing a `fullScreenCover` never re-appears the view
        // underneath it, so the one moment Continue Watching is most likely
        // to have changed — you just watched something — was the one moment
        // neither the rail nor the Top Shelf refreshed. The stop
        // report is still in flight when this fires; `settle()` waits for
        // it so the rails read the new position, not the old.
        .playerPresentation(item: $playerItem, onDismiss: {
            Task {
                await session.client.playbackReports.settle()
                await refreshUserData()
            }
        })
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

    /// The rows to draw, in order, already stripped of the ones this account
    /// hides. Plugin rails are placed by the section they came from, so an
    /// arrangement can put one between two of Lagoon's own rows.
    private var rowOrder: [String] {
        HomeSectionPreferenceResolver.renderOrder(
            preferences: savedHomePreferences,
            pluginSections: viewModel.pluginRails.map {
                HomeRowID.section(forPluginRailID: $0.id)
            }
        )
    }

    /// One row of Home, whichever kind it turns out to be.
    ///
    /// Every branch may still draw nothing: a rail with no items hides itself,
    /// which is what lets one arrangement serve a library that has everything
    /// and one that has almost nothing.
    @ViewBuilder
    private func row(_ id: String) -> some View {
        switch id {
        case HomeRowID.continueWatching:
            MediaRail(
                title: "Continue Watching",
                items: viewModel.resume,
                style: .landscape,
                showsLandscapeMetadata: true,
                playAction: { playerItem = PlayerItem(media: $0) },
                onUserDataChange: refreshUserData
            )
        case HomeRowID.nextUp:
            MediaRail(
                title: "Next Up",
                items: viewModel.nextUp,
                style: .landscape,
                showsLandscapeMetadata: true,
                playAction: { playerItem = PlayerItem(media: $0) },
                onUserDataChange: refreshUserData
            )
        case HomeRowID.favorites:
            MediaRail(
                title: "Favorites",
                items: viewModel.favorites,
                style: .landscape,
                onUserDataChange: refreshUserData
            )
        case HomeRowID.recentlyAddedMovies:
            recentlyAddedRails(collectionType: "movies")
        case HomeRowID.recentlyAddedShows:
            recentlyAddedRails(collectionType: "tvshows")
        case HomeRowID.recentlyAddedOther:
            recentlyAddedRails(collectionType: nil)
        case HomeRowID.movieGenres:
            GenreRail(
                title: "Movie Genres",
                genres: viewModel.movieGenreShelf,
                includeTypes: [.movie],
                identifier: "movies"
            )
        case HomeRowID.showGenres:
            GenreRail(
                title: "Show Genres",
                genres: viewModel.showGenreShelf,
                includeTypes: [.series],
                identifier: "shows"
            )
        case CollectionShelf.rowID:
            CollectionRail(title: "Collections", collections: viewModel.collections)
        case HomeCuratedRows.ID.topMovies, HomeCuratedRows.ID.topShows:
            topTenRail(id)
        default:
            if HomeRowID.isNative(id) {
                curatedRail(id)
            } else {
                pluginRail(id)
            }
        }
    }

    /// The Recently Added rails belonging to one kind of library, so each one
    /// lands where the arrangement puts that kind rather than in a run of its
    /// own.
    ///
    /// A nil `collectionType` collects whatever is neither movies nor shows.
    /// `load` only keeps those two today, so it draws nothing — but a rail
    /// silently vanishing is a worse way to find that out than a rail
    /// appearing in an odd place.
    @ViewBuilder
    private func recentlyAddedRails(collectionType: String?) -> some View {
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

    /// A row the server's Home Screen Sections plugin contributed.
    /// Nothing at all without the plugin, and nothing for a section whose
    /// items came back empty.
    @ViewBuilder
    private func pluginRail(_ section: String) -> some View {
        if let rail = viewModel.pluginRails.first(
            where: { $0.id == HomeRowID.pluginRailID(forSection: section) }
        ) {
            MediaRail(
                title: rail.title,
                items: rail.items,
                style: .landscape,
                onUserDataChange: refreshUserData
            )
        }
    }

    /// One curated row, or nothing at all.
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
        if let rail = viewModel.curatedRails[id] {
            MediaRail(
                title: rail.title,
                items: rail.items,
                style: .landscape,
                onUserDataChange: refreshUserData
            )
        }
    }

    @ViewBuilder
    private func topTenRail(_ id: String) -> some View {
        if let rail = viewModel.curatedRails[id] {
            TopTenRail(
                title: rail.title,
                items: rail.items,
                onUserDataChange: refreshUserData
            )
        }
    }
}
