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

                        // Shown only while in a group whose player is closed.
                        WatchTogetherHomeCard()

                        // Order and visibility: `HomeSectionPreferenceResolver`.
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
        // Dismissing a `fullScreenCover` does not fire `onAppear`, so refresh
        // here. `settle()` waits for the stop report so the rails read the
        // new position.
        .playerPresentation(item: $playerItem, onDismiss: {
            Task {
                await session.client.playbackReports.settle()
                await refreshUserData()
            }
        })
    }

    private func refreshUserData() async {
        await viewModel.refreshProgress(client: session.client)
    }

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

    /// Visible row ids in order; plugin rails can sit between native rows.
    private var rowOrder: [String] {
        HomeSectionPreferenceResolver.renderOrder(
            preferences: savedHomePreferences,
            pluginSections: viewModel.pluginRails.map {
                HomeRowID.section(forPluginRailID: $0.id)
            }
        )
    }

    /// Any branch may draw nothing: an empty rail hides itself.
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

    /// Recently Added rails for one library kind. Nil collects anything that
    /// is neither movies nor shows (nothing today, since `load` keeps only
    /// those two).
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

    /// No `playAction`: discovery rails open the detail page. A series has
    /// no stream, and playing one gets a 500 from PlaybackInfo.
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
