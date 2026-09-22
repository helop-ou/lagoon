import SwiftUI
import Observation

/// Only the rows to draw and the hero. Each rail fetches itself
/// (`SeerrDiscoverRail`), so one dead endpoint cannot sink the page.
@Observable
private final class DiscoverViewModel {
    var rows: [SeerrDiscoverRow] = []
    var hero: [SeerrDiscoverResult] = []
    var isLoading = false
    var errorMessage: String?

    func load(client: SeerrClient) async {
        guard !isLoading else { return }
        isLoading = true
        await loadPage(client: client)
        isLoading = false
    }

    private func loadPage(client: SeerrClient) async {
        errorMessage = nil

        // The server's own arrangement, else Jellyseerr's default order.
        if let sliders = try? await client.discoverSliders() {
            guard !Task.isCancelled else { return }
            rows = SeerrDiscoverLayout.rows(for: sliders)
        } else if rows.isEmpty {
            // A failed refresh must not replace the server's ordering.
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
            // Trending feeds the hero, so this failure is the one to show.
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
                    HeroSection(items: heroItems, isActive: isActive)
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
        .background(Theme.background.ignoresSafeArea())
        .serverRefreshable(
            .discover,
            isActive: isActive,
            isEnabled: seerr.isConnected
        ) {
            refreshGeneration &+= 1
            await viewModel.load(client: seerr.client)
        }
        // Signs in to Seerr with the Jellyfin session, no password. Silent
        // when there is nothing to do; one attempt per activation.
        .task(id: "seerr-auto-signin:\(seerr.configuredURL?.absoluteString ?? "")") {
            await seerr.signInUsingJellyfinIfNeeded(session.client)
        }
        .task(id: "\(seerr.user?.id ?? -1):\(reloadID)") {
            guard seerr.isConnected else { return }
            await viewModel.load(client: seerr.client)
        }
        .accessibilityIdentifier("seerr.discover")
    }

    /// Seerr's API has no logo artwork, so the panel sets each title in type.
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
            // Automatic sign-in is the normal path, so its failure shows here.
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

    /// Movies, Shows and Requests, above the rails. Always one row: on a
    /// phone it scrolls and drops the glyphs; the TV keeps a fixed row.
    private var chips: some View {
        #if os(tvOS)
        HStack(spacing: Metrics.Space.m) {
            chipLinks
        }
        .padding(.horizontal, Metrics.screenGutter)
        .padding(.bottom, Metrics.Space.xl)
        #else
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.Space.m) {
                chipLinks
            }
            .padding(.vertical, Metrics.Space.xs)
        }
        // A content margin keeps the first chip on the gutter while the row
        // scrolls edge to edge.
        .contentMargins(.horizontal, Metrics.screenGutter, for: .scrollContent)
        .scrollClipDisabled()
        .padding(.bottom, Metrics.Space.xl)
        #endif
    }

    @ViewBuilder
    private var chipLinks: some View {
        NavigationLink(value: SeerrNavigationRoute.catalog(.popular(.movie))) {
            chipLabel("Movies", systemImage: ContentIcon.movies)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("seerr.catalog.movies")

        NavigationLink(value: SeerrNavigationRoute.catalog(.popular(.tv))) {
            chipLabel("Shows", systemImage: ContentIcon.shows)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("seerr.catalog.shows")

        NavigationLink(value: SeerrNavigationRoute.requests) {
            chipLabel(requestsTitle, systemImage: "tray.full")
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("seerr.requests")
    }

    private func chipLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            #if os(iOS)
            .labelStyle(.titleOnly)
            .fontWeight(.semibold)
            #endif
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

    let posterLayout = PosterLayout()
    @State private var gridWidth: CGFloat = 0
    private var grid: PosterGrid { posterLayout.grid(fitting: gridWidth) }

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
                    LazyVGrid(columns: grid.columns, spacing: Metrics.gridRowSpacing) {
                        ForEach(viewModel.items) { item in
                            SeerrMediaCard(item: item)
                                .onAppear {
                                    guard item.id == viewModel.items.suffix(5).first?.id else { return }
                                    Task { await viewModel.loadNext(source: source, client: seerr.client) }
                                }
                        }
                        if viewModel.isLoading {
                            let width = grid.cardWidth ?? Metrics.posterWidth
                            ProgressView().frame(width: width, height: (width * 3 / 2).rounded())
                        }
                    }
                    .environment(\.posterCardWidth, grid.cardWidth)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }

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
        .background(Theme.background.ignoresSafeArea())
        .refreshable {
            await viewModel.loadNext(source: source, client: seerr.client, reset: true)
        }
        .task { await viewModel.loadNext(source: source, client: seerr.client) }
        .accessibilityIdentifier("seerr.catalog.\(source.id)")
    }

    private var catalogTitle: String { source.title }
}
