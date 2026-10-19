import SwiftUI

struct HomeView: View {
    @Environment(\.displayScale) private var displayScale
    let isActive: Bool
    let heroFocus: FocusState<Bool>.Binding
    @Environment(SessionStore.self) private var session
    @State private var viewModel = HomeViewModel()
    @State private var playerItem: PlayerItem?

    var body: some View {
        ZStack {
            ThemePageBackground()

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

                        Color.clear.frame(height: Metrics.homeBottomPadding)
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
        .task(id: externalLookupKey) {
            await viewModel.matchExternalTitles(seerr: session.seerr.client)
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
                backdropURL: session.client.imageURL(for: item, kind: .backdrop, maxWidth: Metrics.detailBackdropRequestWidth),
                logoURL: session.client.imageURL(
                    for: item,
                    kind: .logo,
                    maxWidth: ArtworkSizing.pixels(for: Metrics.logoMaxWidth, displayScale: displayScale)
                ),
                route: .item(item)
            )
        }
    }

    private var externalLookupKey: String {
        let ids = viewModel.pluginRails.flatMap(\.externalItems).map(\.id)
        return "\(session.seerr.user?.id ?? -1)|\(ids.joined(separator: ","))"
    }

    private var savedHomePreferences: HomeSectionPreferenceValues {
        HomeSectionPreferencesStore.savedValues(accountID: session.activeAccount?.id)
    }

    /// Visible row ids in order. Plugin rails can sit between native rows.
    private var rowOrder: [String] {
        HomeSectionPreferenceResolver.renderOrder(
            preferences: savedHomePreferences,
            pluginSections: viewModel.pluginRails.compactMap(\.pluginSection)
        )
    }

    /// Any branch may draw nothing: an empty rail hides itself.
    @ViewBuilder
    private func row(_ id: String) -> some View {
        switch HomeRowKind(id: id) {
        case .continueWatching:
            MediaRail(
                title: "Continue Watching",
                items: viewModel.resume,
                style: .landscape,
                showsLandscapeMetadata: true,
                subtitles: viewModel.queueLabels,
                playAction: { playerItem = viewModel.playerItem(for: $0) },
                onUserDataChange: refreshUserData
            )
        case .nextUp:
            MediaRail(
                title: "Next Up",
                items: viewModel.nextUp,
                style: .landscape,
                showsLandscapeMetadata: true,
                subtitles: viewModel.queueLabels,
                playAction: { playerItem = viewModel.playerItem(for: $0) },
                onUserDataChange: refreshUserData
            )
        case .favorites:
            MediaRail(
                title: "Favorites",
                items: viewModel.favorites,
                style: .landscape,
                onUserDataChange: refreshUserData
            )
        case .recentlyAddedMovies:
            recentlyAddedRails(collectionType: "movies")
        case .recentlyAddedShows:
            recentlyAddedRails(collectionType: "tvshows")
        case .movieGenres:
            GenreRail(
                title: "Movie Genres",
                genres: viewModel.movieGenreShelf,
                includeTypes: [.movie],
                identifier: "movies"
            )
        case .showGenres:
            GenreRail(
                title: "Show Genres",
                genres: viewModel.showGenreShelf,
                includeTypes: [.series],
                identifier: "shows"
            )
        case .collections:
            CollectionRail(title: "Collections", collections: viewModel.collections)
        case .playlists:
            CollectionRail(title: "Playlists", collections: viewModel.playlists, identifier: "playlist")
        case .topTen:
            topTenRail(id)
        case .curated:
            curatedRail(id)
        case .plugin(let section):
            pluginRail(section)
        case nil:
            EmptyView()
        }
    }

    /// Recently Added rails for one library kind.
    @ViewBuilder
    private func recentlyAddedRails(collectionType: String) -> some View {
        let rails = viewModel.latestRails.filter { $0.collectionType == collectionType }
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
        ForEach(viewModel.pluginRails.filter { $0.pluginSection == section }) { rail in
            if rail.items.isEmpty {
                ExternalSectionRail(
                    title: rail.title,
                    items: rail.externalItems,
                    seerrTitles: viewModel.externalSeerrTitles
                )
            } else {
                MediaRail(
                    title: rail.title,
                    items: rail.items,
                    style: .landscape,
                    onUserDataChange: refreshUserData
                )
            }
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
