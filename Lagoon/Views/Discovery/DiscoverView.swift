import SwiftUI
import Observation

/// Discover's own state is now only the two things the page as a whole
/// needs: which rows to draw, and what fills the hero. Every rail fetches
/// itself (`SeerrDiscoverRail`), so a slow or dead endpoint no longer holds
/// up or discards the rest of the screen (HEL-114).
@Observable
private final class DiscoverViewModel {
    var rows: [SeerrDiscoverRow] = []
    var hero: [SeerrDiscoverResult] = []
    var isLoading = false
    var errorMessage: String?

    func load(client: SeerrClient) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        // The layout is the server owner's own arrangement where they have
        // one. It is never worth failing the page over: a server that will
        // not answer still gets Jellyseerr's default order.
        if let sliders = try? await client.discoverSliders() {
            guard !Task.isCancelled else { return }
            rows = SeerrDiscoverLayout.rows(for: sliders)
        } else if rows.isEmpty {
            // A transient refresh failure must not replace the server
            // owner's chosen ordering with Lagoon's fallback ordering.
            rows = SeerrDiscoverLayout.fallback
        }

        do {
            let trending = try await client.trending()
            guard !Task.isCancelled else { return }
            hero = Array(
                trending.results
                    .filter { $0.mediaType == .movie || $0.mediaType == .tv }
                    .filter { $0.backdropPath != nil }
                    .prefix(5)
            )
        } catch is CancellationError {
        } catch {
            // Trending is also the hero's source, so failing it is the one
            // fetch that leaves the page with nothing to show at the top.
            errorMessage = error.localizedDescription
        }
    }
}

struct DiscoverView: View {
    let isActive: Bool
    @Environment(SessionStore.self) private var session
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var viewModel = DiscoverViewModel()
    @State private var reloadID = 0
    @State private var refreshGeneration = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if seerr.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
                        .accessibilityLabel("Loading Discover")
                } else if !seerr.isConnected {
                    pageHeader
                    connectionState
                        .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
                } else if viewModel.isLoading, viewModel.hero.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
                        .accessibilityLabel("Loading Discover")
                } else if let error = viewModel.errorMessage, viewModel.hero.isEmpty {
                    pageHeader
                    ErrorStateView(message: error) { reloadID += 1 }
                        .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
                } else {
                    // Artwork first, like Home. The title used to be the
                    // whole top of the screen.
                    HeroSection(items: heroItems)
                        .padding(.top, Metrics.Space.s)
                        .padding(.bottom, Metrics.Space.xl)

                    chips

                    ForEach(viewModel.rows) { row in
                        switch row {
                        case .media(let source):
                            SeerrDiscoverRail(
                                source: source,
                                refreshGeneration: refreshGeneration
                            )
                        case .genres(let mediaType):
                            SeerrGenreRail(
                                mediaType: mediaType,
                                title: row.title,
                                refreshGeneration: refreshGeneration
                            )
                        }
                    }
                }
            }
            .padding(.bottom, Metrics.Space.section)
        }
        .scrollClipDisabled()
        .background(Color.black.ignoresSafeArea())
        .serverRefreshable(
            .discover,
            isActive: isActive,
            isEnabled: seerr.isConnected
        ) {
            refreshGeneration &+= 1
            await viewModel.load(client: seerr.client)
        }
        // A viewer already signed in to Jellyfin should not meet a second
        // login. This uses the Jellyfin session Lagoon holds to sign in to
        // Seerr without a password; it is silent when there is nothing to do
        // and gives up after one attempt per activation (HEL-95).
        .task(id: "seerr-auto-signin:\(seerr.configuredURL?.absoluteString ?? "")") {
            await seerr.signInUsingJellyfinIfNeeded(session.client)
        }
        .task(id: "\(seerr.user?.id ?? -1):\(reloadID)") {
            guard seerr.isConnected else { return }
            await viewModel.load(client: seerr.client)
        }
        .accessibilityIdentifier("seerr.discover")
    }

    /// Seerr's half of the shared hero. There is no logo artwork anywhere in
    /// its API, so `logoURL` is nil and the panel sets the title in type.
    private var heroItems: [HeroItem<SeerrNavigationRoute>] {
        viewModel.hero.compactMap { item in
            guard let type = item.mediaType else { return nil }
            return HeroItem(
                id: "\(item.id)",
                title: item.displayTitle,
                overview: item.overview,
                backdropURL: SeerrClient.imageURL(path: item.backdropPath, width: 1920),
                logoURL: nil,
                route: .media(id: item.id, type: type)
            )
        }
    }

    private var connectionState: some View {
        VStack(spacing: Metrics.Space.l) {
            Image(systemName: "sparkles.tv")
                .font(Typography.largeGlyph)
                .foregroundStyle(.secondary)
            Text(seerr.isConfigured ? "Sign In to Seerr" : "Connect Seerr")
                .font(.title3.bold())
            Text(seerr.isConfigured
                 ? "Connect this Jellyfin user to browse and manage requests."
                 : "Add your Seerr server to browse movies and shows outside your library.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)
            // Signing in automatically is the normal path, so when it does
            // not work the reason belongs here rather than only in Settings.
            if seerr.isConfigured, let message = seerr.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 700)
            }
            NavigationLink(value: SeerrNavigationRoute.settings) {
                Text(seerr.isConfigured ? "Sign In" : "Set Up Seerr")
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("seerr.setup")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Movies, Shows and Requests as destinations, kept above the rails
    /// where they are reachable without scrolling past eight of them.
    private var chips: some View {
        HStack(spacing: Metrics.Space.m) {
            NavigationLink(value: SeerrNavigationRoute.catalog(.popular(.movie))) {
                Label("Movies", systemImage: ContentIcon.movies)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("seerr.catalog.movies")

            NavigationLink(value: SeerrNavigationRoute.catalog(.popular(.tv))) {
                Label("Shows", systemImage: ContentIcon.shows)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("seerr.catalog.shows")

            NavigationLink(value: SeerrNavigationRoute.requests) {
                Label(requestsTitle, systemImage: "tray.full")
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("seerr.requests")
        }
        .padding(.horizontal, Metrics.screenGutter)
        .padding(.bottom, Metrics.Space.xl)
    }

    private var pageHeader: some View {
        Text("Discover")
            .font(.largeTitle.bold())
            .padding(.horizontal, Metrics.screenGutter)
            .padding(.top, Metrics.Space.xxl)
            .padding(.bottom, Metrics.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var requestsTitle: String {
        seerr.user?.canViewAllRequests == true ? "All Requests" : "My Requests"
    }

}

@Observable
private final class SeerrCatalogViewModel {
    var items: [SeerrDiscoverResult] = []
    var page = 0
    var totalPages = 1
    var isLoading = false
    var errorMessage: String?

    func loadNext(source: SeerrCatalogSource, client: SeerrClient, reset: Bool = false) async {
        guard !isLoading else { return }
        if reset {
            items = []
            page = 0
            totalPages = 1
        }
        guard page < totalPages else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let result = try await client.page(for: source, page: page + 1)
            guard !Task.isCancelled else { return }
            let existing = Set(items.map(\.id))
            items += result.results.filter { !existing.contains($0.id) }
            page = result.page
            totalPages = result.totalPages
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SeerrCatalogView: View {
    let source: SeerrCatalogSource
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var viewModel = SeerrCatalogViewModel()

    private var columns: [GridItem] { Metrics.posterGridColumns }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.Space.xxl) {
                Text(catalogTitle)
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("seerr.catalog.title")

                if viewModel.isLoading, viewModel.items.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
                        .accessibilityLabel("Loading \(catalogTitle)")
                } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                    ErrorStateView(message: error) {
                        Task { await viewModel.loadNext(source: source, client: seerr.client, reset: true) }
                    }
                    .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
                } else {
                    LazyVGrid(columns: columns, spacing: Metrics.gridRowSpacing) {
                        ForEach(viewModel.items) { item in
                            SeerrMediaCard(item: item)
                                .onAppear {
                                    guard item.id == viewModel.items.suffix(5).first?.id else { return }
                                    Task { await viewModel.loadNext(source: source, client: seerr.client) }
                                }
                        }
                        if viewModel.isLoading {
                            ProgressView().frame(width: Metrics.posterWidth, height: Metrics.posterHeight)
                        }
                    }

                    if let error = viewModel.errorMessage, !viewModel.isLoading {
                        InlineRetryView(message: error) {
                            Task {
                                await viewModel.loadNext(
                                    source: source,
                                    client: seerr.client
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.screenGutter)
            .padding(.vertical, Metrics.Space.xxl)
        }
        .scrollClipDisabled()
        .background(Color.black.ignoresSafeArea())
        .refreshable {
            await viewModel.loadNext(source: source, client: seerr.client, reset: true)
        }
        .task { await viewModel.loadNext(source: source, client: seerr.client) }
        .accessibilityIdentifier("seerr.catalog.\(source.id)")
    }

    private var catalogTitle: String { source.title }
}
