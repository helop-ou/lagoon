import SwiftUI
import Observation

@Observable
private final class DiscoverViewModel {
    var trending: [SeerrDiscoverResult] = []
    var movies: [SeerrDiscoverResult] = []
    var shows: [SeerrDiscoverResult] = []
    var upcoming: [SeerrDiscoverResult] = []
    var isLoading = false
    var errorMessage: String?

    func load(client: SeerrClient) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            async let trendingPage = client.trending()
            async let moviePage = client.discover(.movie)
            async let showPage = client.discover(.tv)
            async let upcomingPage = client.upcomingMovies()
            let pages = try await (trendingPage, moviePage, showPage, upcomingPage)
            guard !Task.isCancelled else { return }
            trending = pages.0.results
            movies = pages.1.results
            shows = pages.2.results
            upcoming = pages.3.results
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DiscoverView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var viewModel = DiscoverViewModel()
    @State private var reloadID = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                pageHeader

                if seerr.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
                        .accessibilityLabel("Loading Discover")
                } else if !seerr.isConnected {
                    connectionState
                        .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
                } else if viewModel.isLoading, viewModel.trending.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
                        .accessibilityLabel("Loading Discover")
                } else if let error = viewModel.errorMessage, viewModel.trending.isEmpty {
                    ErrorStateView(message: error) { reloadID += 1 }
                        .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
                } else {
                    discoverySections
                }
            }
            .padding(.bottom, Metrics.Space.section)
        }
        .scrollClipDisabled()
        .background(Color.black.ignoresSafeArea())
        .refreshable {
            guard seerr.isConnected else { return }
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

    @ViewBuilder
    private var discoverySections: some View {
        HStack(spacing: Metrics.Space.m) {
            NavigationLink(value: SeerrNavigationRoute.catalog(.movie)) {
                Label("Movies", systemImage: ContentIcon.movies)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("seerr.catalog.movies")

            NavigationLink(value: SeerrNavigationRoute.catalog(.tv)) {
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

        SeerrMediaRail(title: "Trending", items: viewModel.trending)
        SeerrMediaRail(title: "Popular Movies", items: viewModel.movies)
        SeerrMediaRail(title: "Popular Shows", items: viewModel.shows)
        SeerrMediaRail(title: "Upcoming Movies", items: viewModel.upcoming)
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

    func loadNext(mediaType: SeerrMediaType, client: SeerrClient, reset: Bool = false) async {
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
            let result = try await client.discover(mediaType, page: page + 1)
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
    let mediaType: SeerrMediaType
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
                        Task { await viewModel.loadNext(mediaType: mediaType, client: seerr.client, reset: true) }
                    }
                    .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
                } else {
                    LazyVGrid(columns: columns, spacing: Metrics.gridRowSpacing) {
                        ForEach(viewModel.items) { item in
                            SeerrMediaCard(item: item)
                                .onAppear {
                                    guard item.id == viewModel.items.suffix(5).first?.id else { return }
                                    Task { await viewModel.loadNext(mediaType: mediaType, client: seerr.client) }
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
                                    mediaType: mediaType,
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
            await viewModel.loadNext(mediaType: mediaType, client: seerr.client, reset: true)
        }
        .task { await viewModel.loadNext(mediaType: mediaType, client: seerr.client) }
        .accessibilityIdentifier("seerr.catalog.\(mediaType.rawValue)")
    }

    private var catalogTitle: String {
        mediaType == .movie ? "Discover Movies" : "Discover Shows"
    }
}
